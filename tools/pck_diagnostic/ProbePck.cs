// Read-only, bounded-memory probe independent of the installer's PCK reader.
// PCK v2 offsets: https://github.com/godotengine/godot/blob/4.1/core/io/file_access_pack.cpp
using System;
using System.Collections.Generic;
using System.IO;
using System.Security.Cryptography;
using System.Text;

public static class UntilThenPckProbe
{
    const string Target = "res://.godot/extension_list.cfg";
    const int Limit = 1024 * 1024;
    static readonly Encoding Utf8 = new UTF8Encoding(false, true);

    sealed class Record
    {
        public string Name, Expected;
        public long StoredOffset, Offset, Size;
        public uint Flags;
    }

    static FileStream ReadOnly(string path)
    {
        return new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read, 65536);
    }

    static string Hex(byte[] bytes)
    {
        return BitConverter.ToString(bytes).Replace("-", "").ToLowerInvariant();
    }

    static byte[] Exact(BinaryReader reader, int count)
    {
        byte[] bytes = reader.ReadBytes(count);
        if (bytes.Length != count) throw new EndOfStreamException("Truncated PCK directory.");
        return bytes;
    }

    static void ReadAt(FileStream stream, long offset, byte[] bytes, int count)
    {
        stream.Position = offset;
        int done = 0;
        while (done < count)
        {
            int n = stream.Read(bytes, done, count - done);
            if (n == 0) throw new EndOfStreamException("Short resource read.");
            done += n;
        }
    }

    static string Blocks(byte[] bytes, int count)
    {
        // Keep the incremental provider separate from ComputeHash's provider state.
        using (var md5 = MD5.Create())
        {
            for (int i = 0; i < count; i += 8191)
                md5.TransformBlock(bytes, i, Math.Min(8191, count - i), bytes, i);
            md5.TransformFinalBlock(new byte[0], 0, 0);
            return Hex(md5.Hash);
        }
    }

    public static string SelfTest()
    {
        using (var md5 = MD5.Create())
        {
            byte[] abc = Encoding.ASCII.GetBytes("abc");
            string empty = Hex(md5.ComputeHash(new byte[0]));
            string direct = Hex(md5.ComputeHash(abc));
            string blocks = Blocks(abc, abc.Length);
            return "MD5 provider: " + md5.GetType().FullName + Environment.NewLine +
                "MD5 self-test: " + (empty == "d41d8cd98f00b204e9800998ecf8427e" &&
                direct == "900150983cd24fb0d6963f7d28e17f72" && blocks == direct ? "PASS" : "FAIL") +
                " (empty=" + empty + ", abc=" + direct + ", blocks=" + blocks + ")";
        }
    }

    public static string Inspect(string path)
    {
        var log = new StringBuilder();
        log.AppendLine("FILE: " + Path.GetFullPath(path));
        try
        {
            using (var index = ReadOnly(path))
            using (var data = ReadOnly(path))
            using (var reader = new BinaryReader(index, Utf8, true))
            using (var md5 = MD5.Create())
            {
                log.AppendLine("Bytes: " + index.Length);
                log.AppendLine("LastWriteUtc: " + File.GetLastWriteTimeUtc(path).ToString("o"));
                uint magic = reader.ReadUInt32(), format = reader.ReadUInt32();
                uint major = reader.ReadUInt32(), minor = reader.ReadUInt32(), patch = reader.ReadUInt32();
                uint flags = reader.ReadUInt32();
                long fileBase = checked((long)reader.ReadUInt64());
                Exact(reader, 64);
                uint count = reader.ReadUInt32();
                log.AppendLine(String.Format("Header: magic={0:X8}; format={1}; Godot={2}.{3}.{4}; flags={5}; fileBase={6}; count={7}",
                    magic, format, major, minor, patch, flags, fileBase, count));
                if (magic != 0x43504447 || format != 2 || major != 4 || flags != 0 ||
                    count == 0 || count > 2000000 || fileBase > index.Length)
                    throw new InvalidDataException("Unsupported or invalid PCK header.");

                var samples = new List<Record>();
                long firstOffset = long.MaxValue;
                bool foundTarget = false;
                for (uint i = 0; i < count; i++)
                {
                    uint length = reader.ReadUInt32();
                    if (length == 0 || length > 4096) throw new InvalidDataException("Invalid path length at entry " + i);
                    string name = Utf8.GetString(Exact(reader, (int)length)).TrimEnd('\0');
                    if (name.Length == 0 || name.IndexOf('\0') >= 0) throw new InvalidDataException("Invalid resource path.");
                    if (!name.StartsWith("res://", StringComparison.Ordinal)) name = "res://" + name;
                    long stored = checked((long)reader.ReadUInt64());
                    long size = checked((long)reader.ReadUInt64());
                    string expected = Hex(Exact(reader, 16));
                    uint entryFlags = reader.ReadUInt32();
                    long offset = checked(fileBase + stored);
                    if (offset < 100 || offset > index.Length || size > index.Length - offset)
                        throw new InvalidDataException("Resource outside PCK: " + name + "; offset=" + offset + "; size=" + size);
                    firstOffset = Math.Min(firstOffset, offset);
                    if (name == Target) foundTarget = true;
                    if (i < 8 || name == Target)
                        samples.Add(new Record { Name = name, Expected = expected, StoredOffset = stored,
                            Offset = offset, Size = size, Flags = entryFlags });
                }
                if (firstOffset < index.Position) throw new InvalidDataException("Resource data overlaps the directory.");
                log.AppendLine("Directory end: " + index.Position + "; target found: " + foundTarget);
                byte[] buffer = new byte[Limit];
                int checkedCount = 0, failures = 0;
                foreach (Record sample in samples)
                {
                    log.AppendLine("RESOURCE: " + sample.Name);
                    log.AppendLine("  storedOffset=" + sample.StoredOffset + "; absoluteOffset=" + sample.Offset +
                        "; size=" + sample.Size + "; flags=" + sample.Flags);
                    log.AppendLine("  expected=" + sample.Expected);
                    if (sample.Size > Limit || sample.Flags != 0)
                    {
                        log.AppendLine("  SKIPPED: sample is larger than 1 MB or has unsupported flags.");
                        continue;
                    }
                    int size = (int)sample.Size;
                    ReadAt(data, sample.Offset, buffer, size);
                    string actual = Hex(md5.ComputeHash(buffer, 0, size));
                    string blocks = Blocks(buffer, size);
                    using (var repeated = ReadOnly(path)) ReadAt(repeated, sample.Offset, buffer, size);
                    string again = Hex(md5.ComputeHash(buffer, 0, size));
                    bool matches = actual == sample.Expected && blocks == actual && again == actual;
                    log.AppendLine("  actual=" + actual + "; incremental=" + blocks + "; reread=" + again);
                    log.AppendLine("  " + (matches ? "MATCH" : "MISMATCH"));
                    checkedCount++;
                    if (!matches) failures++;
                    // Diagnostic comparison only. Never use this alternate interpretation to install.
                    if (!matches && fileBase != 0 && sample.StoredOffset >= index.Position &&
                        sample.StoredOffset <= data.Length && sample.Size <= data.Length - sample.StoredOffset)
                    {
                        ReadAt(data, sample.StoredOffset, buffer, size);
                        string alternate = Hex(md5.ComputeHash(buffer, 0, size));
                        log.AppendLine("  ignoring_fileBase_md5=" + alternate + "; matches_expected=" + (alternate == sample.Expected));
                    }
                }
                log.AppendLine("SAMPLE SUMMARY: checked=" + checkedCount + "; mismatches=" + failures);
                log.AppendLine("This is a targeted sample check, not a full PCK integrity check.");
            }
        }
        catch (Exception error)
        {
            log.AppendLine("READ ERROR: " + error.GetType().Name + ": " + error.Message);
        }
        return log.ToString();
    }
}
