// Godot 4 PCK v2, unencrypted standalone packs only. Windows PowerShell 5.1 / .NET Framework.
// File contents AND the original directory are streamed; only payload metadata stays in RAM.
// Format reference: https://github.com/godotengine/godot/blob/4.1/core/io/pck_packer.cpp
using System;
using System.Collections.Generic;
using System.IO;
using System.Security.Cryptography;
using System.Text;

namespace UntilThenThaiMod
{
    public static class LowMemoryPck
    {
        const uint Magic = 0x43504447;
        const int BufferSize = 1024 * 1024;
        static readonly Encoding Utf8 = new UTF8Encoding(false, true);
        static readonly byte[] Empty = new byte[0];
        static readonly byte[] Padding = new byte[16];

        internal sealed class Header
        {
            internal uint Major, Minor, Patch, Count;
            internal long FileBase;
        }

        internal sealed class Entry
        {
            internal string Path, Source;
            internal byte[] RawPath, Digest;
            internal long Offset, Size;
            internal bool InBase;
        }

        public sealed class Plan : IDisposable
        {
            internal FileStream Input;
            internal Header Header;
            internal Dictionary<string, Entry> Payload;
            internal List<Entry> Added;
            internal long DataStart;
            public long OutputLength { get; internal set; }
            public uint FileCount { get; internal set; }
            public void Dispose() { if (Input != null) { Input.Dispose(); Input = null; } }
        }

        static FileStream OpenRead(string path)
        {
            return new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read, 65536);
        }

        static long Align(long value) { return checked((value + 15) / 16 * 16); }

        static byte[] Exact(BinaryReader reader, int count)
        {
            byte[] data = reader.ReadBytes(count);
            if (data.Length != count) throw new InvalidDataException("Truncated PCK directory.");
            return data;
        }

        static Header ReadHeader(Stream stream)
        {
            stream.Position = 0;
            var r = new BinaryReader(stream, Utf8, true);
            if (r.ReadUInt32() != Magic || r.ReadUInt32() != 2)
                throw new InvalidDataException("Expected a standalone Godot PCK format 2 file.");
            var h = new Header { Major = r.ReadUInt32(), Minor = r.ReadUInt32(), Patch = r.ReadUInt32() };
            if (h.Major != 4 || r.ReadUInt32() != 0)
                throw new InvalidDataException("Unsupported engine version or encrypted PCK directory.");
            h.FileBase = checked((long)r.ReadUInt64());
            Exact(r, 64);
            h.Count = r.ReadUInt32();
            if (h.Count == 0 || h.Count > 2000000 || h.FileBase > stream.Length)
                throw new InvalidDataException("Invalid PCK header.");
            return h;
        }

        static IEnumerable<Entry> Entries(Stream stream, Header h)
        {
            stream.Position = 100;
            var r = new BinaryReader(stream, Utf8, true);
            for (uint i = 0; i < h.Count; i++)
            {
                uint length = r.ReadUInt32();
                if (length == 0 || length > 4096) throw new InvalidDataException("Invalid PCK path length.");
                var e = new Entry { RawPath = Exact(r, (int)length) };
                e.Path = Utf8.GetString(e.RawPath).TrimEnd('\0');
                if (e.Path.Length == 0 || e.Path.IndexOf('\0') >= 0)
                    throw new InvalidDataException("Invalid PCK path.");
                if (!e.Path.StartsWith("res://", StringComparison.Ordinal)) e.Path = "res://" + e.Path;
                e.Offset = checked(h.FileBase + (long)r.ReadUInt64());
                e.Size = checked((long)r.ReadUInt64());
                e.Digest = Exact(r, 16);
                if (r.ReadUInt32() != 0) throw new InvalidDataException("Encrypted/unsupported resource: " + e.Path);
                if (e.Offset < 100 || e.Offset > stream.Length || e.Size > stream.Length - e.Offset)
                    throw new InvalidDataException("Resource lies outside the PCK: " + e.Path);
                yield return e;
            }
        }

        static bool Same(byte[] a, byte[] b)
        {
            if (a.Length != b.Length) return false;
            for (int i = 0; i < a.Length; i++) if (a[i] != b[i]) return false;
            return true;
        }

        // A fixed buffer, also for very large textures/fonts. No ReadAllBytes, tasks or worker pool.
        static byte[] Transfer(Stream input, Stream output, long length, byte[] buffer, HashAlgorithm hash)
        {
            hash.Initialize();
            while (length > 0)
            {
                int n = input.Read(buffer, 0, (int)Math.Min(buffer.Length, length));
                if (n == 0) throw new EndOfStreamException("File ended during copy/verification.");
                if (output != null) output.Write(buffer, 0, n);
                hash.TransformBlock(buffer, 0, n, buffer, 0);
                length -= n;
            }
            hash.TransformFinalBlock(Empty, 0, 0);
            return hash.Hash;
        }

        static IEnumerable<string> PayloadFiles(string root)
        {
            foreach (string file in Directory.EnumerateFiles(root))
            {
                if ((File.GetAttributes(file) & FileAttributes.ReparsePoint) != 0)
                    throw new InvalidDataException("Payload must not contain links: " + file);
                yield return file;
            }
            foreach (string dir in Directory.EnumerateDirectories(root))
            {
                if ((File.GetAttributes(dir) & FileAttributes.ReparsePoint) != 0)
                    throw new InvalidDataException("Payload must not contain links: " + dir);
                foreach (string file in PayloadFiles(dir)) yield return file;
            }
        }

        public static Plan Prepare(string source, string payloadFolder, int expectedCount)
        {
            var p = new Plan();
            try
            {
                p.Input = OpenRead(source); // Keep source locked against writes until Build finishes.
                p.Header = ReadHeader(p.Input);
                p.Payload = new Dictionary<string, Entry>(StringComparer.Ordinal);
                p.Added = new List<Entry>();
                string root = Path.GetFullPath(payloadFolder).TrimEnd('\\', '/') + Path.DirectorySeparatorChar;
                byte[] buffer = new byte[BufferSize];
                using (var md5 = MD5.Create())
                foreach (string file in PayloadFiles(root))
                {
                    string path = "res://" + file.Substring(root.Length).Replace('\\', '/');
                    byte[] raw = Utf8.GetBytes(path);
                    Array.Resize(ref raw, (raw.Length + 3) / 4 * 4);
                    if (raw.Length > 4096) throw new InvalidDataException("Payload path is too long.");
                    var e = new Entry { Path = path, RawPath = raw, Source = file };
                    using (var input = OpenRead(file))
                    {
                        e.Size = input.Length;
                        e.Digest = Transfer(input, null, e.Size, buffer, md5);
                    }
                    p.Payload.Add(path, e);
                }
                if (p.Payload.Count == 0 || (expectedCount >= 0 && p.Payload.Count != expectedCount))
                    throw new InvalidDataException("Incomplete payload: found " + p.Payload.Count + ", expected " + expectedCount + ". Extract the whole ZIP again.");

                long dataLength = 0, firstOffset = long.MaxValue;
                foreach (Entry original in Entries(p.Input, p.Header))
                {
                    firstOffset = Math.Min(firstOffset, original.Offset);
                    Entry replacement;
                    if (p.Payload.TryGetValue(original.Path, out replacement))
                    {
                        if (replacement.InBase) throw new InvalidDataException("Duplicate resource: " + original.Path);
                        replacement.InBase = true;
                        dataLength = checked(dataLength + Align(replacement.Size));
                    }
                    else dataLength = checked(dataLength + Align(original.Size));
                }
                long directoryEnd = p.Input.Position;
                if (firstOffset < directoryEnd) throw new InvalidDataException("PCK data overlaps its directory.");
                p.FileCount = p.Header.Count;
                foreach (Entry e in p.Payload.Values)
                {
                    if (e.InBase) continue;
                    p.Added.Add(e);
                    directoryEnd = checked(directoryEnd + 40 + e.RawPath.Length);
                    dataLength = checked(dataLength + Align(e.Size));
                    p.FileCount++;
                }
                p.Added.Sort((a, b) => StringComparer.Ordinal.Compare(a.Path, b.Path));
                p.DataStart = Align(directoryEnd);
                p.OutputLength = checked(p.DataStart + dataLength);
                return p;
            }
            catch { p.Dispose(); throw; }
        }

        static void WriteEntry(BinaryWriter writer, Entry e, byte[] rawPath, ref long offset)
        {
            writer.Write((uint)rawPath.Length);
            writer.Write(rawPath);
            writer.Write((ulong)offset);
            writer.Write((ulong)e.Size);
            writer.Write(e.Digest);
            writer.Write((uint)0);
            offset = checked(offset + Align(e.Size));
        }

        static void CopyEntry(Entry e, FileStream original, Stream output, byte[] buffer, HashAlgorithm md5)
        {
            byte[] actual;
            if (e.Source == null)
            {
                original.Position = e.Offset;
                actual = Transfer(original, output, e.Size, buffer, md5);
            }
            else
            {
                using (var input = OpenRead(e.Source))
                {
                    if (input.Length != e.Size) throw new IOException("Payload changed during installation: " + e.Path);
                    actual = Transfer(input, output, e.Size, buffer, md5);
                }
            }
            if (!Same(actual, e.Digest)) throw new InvalidDataException("Checksum mismatch: " + e.Path);
            output.Write(Padding, 0, (int)(Align(e.Size) - e.Size));
        }

        static void Progress(string stage, uint done, uint total, ref int previous)
        {
            int percent = (int)((long)done * 100 / total);
            if (percent / 5 != previous / 5 || done == total)
            {
                previous = percent;
                Console.WriteLine("[..] {0}: {1}% ({2}/{3} files)", stage, percent, done, total);
            }
        }

        public static void Build(Plan p, string outputPath)
        {
            if (p.Input == null) throw new ObjectDisposedException("Plan");
            bool created = false;
            try
            {
                using (var output = new FileStream(outputPath, FileMode.CreateNew, FileAccess.Write, FileShare.None, 65536))
                using (var data = OpenRead(p.Input.Name))
                using (var md5 = MD5.Create())
                {
                    created = true;
                    var writer = new BinaryWriter(output, Utf8, true);
                    writer.Write(Magic); writer.Write((uint)2);
                    writer.Write(p.Header.Major); writer.Write(p.Header.Minor); writer.Write(p.Header.Patch);
                    writer.Write((uint)0); writer.Write((ulong)p.DataStart);
                    writer.Write(new byte[64]); writer.Write(p.FileCount);
                    long offset = 0;
                    foreach (Entry original in Entries(p.Input, p.Header))
                    {
                        Entry replacement;
                        Entry e = p.Payload.TryGetValue(original.Path, out replacement) ? replacement : original;
                        WriteEntry(writer, e, original.RawPath, ref offset);
                    }
                    foreach (Entry e in p.Added) WriteEntry(writer, e, e.RawPath, ref offset);
                    output.Write(Padding, 0, (int)(p.DataStart - output.Position));
                    byte[] buffer = new byte[BufferSize];
                    uint done = 0; int progress = -5;
                    foreach (Entry original in Entries(p.Input, p.Header))
                    {
                        Entry replacement;
                        Entry e = p.Payload.TryGetValue(original.Path, out replacement) ? replacement : original;
                        CopyEntry(e, data, output, buffer, md5);
                        Progress("Building", ++done, p.FileCount, ref progress);
                    }
                    foreach (Entry e in p.Added)
                    {
                        CopyEntry(e, data, output, buffer, md5);
                        Progress("Building", ++done, p.FileCount, ref progress);
                    }
                    if (output.Position != p.OutputLength) throw new InvalidDataException("Output length differs from plan.");
                    output.Flush(true);
                }
                Verify(outputPath); // Read back every resource before the caller replaces the game.
            }
            catch
            {
                if (created) { try { File.Delete(outputPath); } catch { } }
                throw;
            }
        }

        public static void Verify(string path)
        {
            using (var index = OpenRead(path))
            using (var data = OpenRead(path))
            using (var md5 = MD5.Create())
            {
                Header h = ReadHeader(index);
                long firstOffset = long.MaxValue;
                foreach (Entry e in Entries(index, h)) firstOffset = Math.Min(firstOffset, e.Offset);
                if (firstOffset < index.Position) throw new InvalidDataException("PCK data overlaps its directory.");
                byte[] buffer = new byte[BufferSize];
                uint done = 0; int progress = -5;
                foreach (Entry e in Entries(index, h))
                {
                    data.Position = e.Offset;
                    if (!Same(Transfer(data, null, e.Size, buffer, md5), e.Digest))
                        throw new InvalidDataException("Checksum mismatch: " + e.Path);
                    Progress("Verifying", ++done, h.Count, ref progress);
                }
            }
        }
    }
}
