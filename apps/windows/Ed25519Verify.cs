using System.Numerics;
using System.Security.Cryptography;

namespace PttDictate;

/// <summary>
/// Minimal, self-contained Ed25519 signature verification (RFC 8032). .NET 9 has no
/// built-in Ed25519 API, and this is used only to verify the signed license token from
/// nesso.tech (see License.cs), which happens at most a couple of times per day. Point
/// arithmetic is done in plain affine coordinates with System.Numerics.BigInteger: that
/// is far slower than a production limb-based implementation, but it is much easier to
/// write correctly, and correctness matters far more than speed here.
///
/// The public key used to verify the license server's signature is fixed in License.cs;
/// this class only implements Verify, never signing, so it cannot be used to forge a
/// license on its own.
/// </summary>
internal static class Ed25519Verify
{
    // Curve25519 / Ed25519 field prime: 2^255 - 19.
    private static readonly BigInteger P = BigInteger.Pow(2, 255) - 19;

    // Order of the base point (RFC 8032 section 5.1): 2^252 + 27742317777372353535851937790883648493.
    private static readonly BigInteger L = BigInteger.Pow(2, 252) + BigInteger.Parse("27742317777372353535851937790883648493");

    // Twisted Edwards curve parameter: d = -121665/121666 mod p.
    private static readonly BigInteger D = Mod(-121665 * ModInverse(121666, P), P);

    // sqrt(-1) mod p, used by the point-decompression square root (p is congruent to 5 mod 8).
    private static readonly BigInteger SqrtMinus1 = BigInteger.ModPow(2, (P - 1) / 4, P);

    private static readonly (BigInteger X, BigInteger Y) BasePoint = ComputeBasePoint();

    /// <summary>
    /// Returns true only if <paramref name="signature"/> (64 bytes: R || S) is a genuine
    /// Ed25519 signature by <paramref name="publicKey"/> (32 bytes) over exactly the bytes
    /// in <paramref name="message"/>. Any malformed input returns false rather than throwing.
    /// </summary>
    public static bool Verify(byte[] publicKey, byte[] message, byte[] signature)
    {
        try
        {
            if (publicKey.Length != 32 || signature.Length != 64) return false;

            var rBytes = signature[..32];
            var sBytes = signature[32..];

            var s = DecodeScalar(sBytes);
            if (s >= L) return false; // reject a non-canonical S (RFC 8032 section 5.1.7)

            if (!TryDecodePoint(publicKey, out var a)) return false;
            if (!TryDecodePoint(rBytes, out var r)) return false;

            var hash = SHA512.HashData(Concat(rBytes, publicKey, message));
            var k = Mod(DecodeScalar(hash), L);

            var sb = ScalarMultiply(s, BasePoint);
            var ka = ScalarMultiply(k, a);
            var rPlusKa = PointAdd(r, ka);

            return sb.X == rPlusKa.X && sb.Y == rPlusKa.Y;
        }
        catch
        {
            return false;
        }
    }

    private static (BigInteger X, BigInteger Y) ComputeBasePoint()
    {
        // RFC 8032 section 5.1: the base point's y coordinate is 4/5 mod p, and its x
        // coordinate is the positive (even) root recovered from that y.
        var y = Mod(4 * ModInverse(5, P), P);
        var x = RecoverX(y, sign: 0) ?? throw new InvalidOperationException("Ed25519 base point derivation failed.");
        return (x, y);
    }

    private static bool TryDecodePoint(byte[] bytes, out (BigInteger X, BigInteger Y) point)
    {
        point = default;
        if (bytes.Length != 32) return false;

        var sign = (bytes[31] >> 7) & 1;
        var yBytes = (byte[])bytes.Clone();
        yBytes[31] &= 0x7F;
        var y = new BigInteger(yBytes, isUnsigned: true, isBigEndian: false);
        if (y >= P) return false;

        var x = RecoverX(y, sign);
        if (x is null) return false;

        point = (x.Value, y);
        return true;
    }

    // Standard Ed25519 point-decompression square root: recovers x from y and a target
    // parity bit such that -x^2 + y^2 = 1 + d*x^2*y^2 (mod p). Returns null for an
    // encoding that is not a valid curve point.
    private static BigInteger? RecoverX(BigInteger y, int sign)
    {
        var yy = Mod(y * y, P);
        var u = Mod(yy - 1, P);
        var v = Mod(D * yy + 1, P);
        var x2 = Mod(u * ModInverse(v, P), P);

        if (x2 == 0)
        {
            if (sign != 0) return null;
            return BigInteger.Zero;
        }

        var x = BigInteger.ModPow(x2, (P + 3) / 8, P);
        if (Mod(x * x - x2, P) != 0)
        {
            x = Mod(x * SqrtMinus1, P);
            if (Mod(x * x - x2, P) != 0) return null;
        }

        var parity = (x % 2 == 1) ? 1 : 0;
        if (parity != sign) x = P - x;
        return x;
    }

    // Unified addition law for a twisted Edwards curve with a = -1 (Ed25519's shape).
    // This formula is "complete": it also correctly handles doubling (p1 == p2) and the
    // identity element, so callers never need a special case.
    private static (BigInteger X, BigInteger Y) PointAdd((BigInteger X, BigInteger Y) p1, (BigInteger X, BigInteger Y) p2)
    {
        var (x1, y1) = p1;
        var (x2, y2) = p2;
        var dxy = Mod(D * x1 * x2 * y1 * y2, P);
        var xNum = Mod(x1 * y2 + y1 * x2, P);
        var yNum = Mod(y1 * y2 + x1 * x2, P);
        var xDen = ModInverse(Mod(1 + dxy, P), P);
        var yDen = ModInverse(Mod(1 - dxy, P), P);
        return (Mod(xNum * xDen, P), Mod(yNum * yDen, P));
    }

    private static (BigInteger X, BigInteger Y) ScalarMultiply(BigInteger scalar, (BigInteger X, BigInteger Y) point)
    {
        var result = (X: BigInteger.Zero, Y: BigInteger.One); // the curve's identity element
        var addend = point;
        var k = scalar;
        while (k > 0)
        {
            if ((k & 1) == 1) result = PointAdd(result, addend);
            addend = PointAdd(addend, addend);
            k >>= 1;
        }
        return result;
    }

    private static BigInteger DecodeScalar(byte[] bytes) => new(bytes, isUnsigned: true, isBigEndian: false);

    private static BigInteger Mod(BigInteger value, BigInteger modulus)
    {
        var remainder = value % modulus;
        return remainder < 0 ? remainder + modulus : remainder;
    }

    // modulus must be prime; uses Fermat's little theorem (a^(p-2) == a^-1 mod p).
    private static BigInteger ModInverse(BigInteger value, BigInteger modulus) => BigInteger.ModPow(Mod(value, modulus), modulus - 2, modulus);

    private static byte[] Concat(params byte[][] arrays)
    {
        var total = 0;
        foreach (var array in arrays) total += array.Length;
        var result = new byte[total];
        var offset = 0;
        foreach (var array in arrays)
        {
            Buffer.BlockCopy(array, 0, result, offset, array.Length);
            offset += array.Length;
        }
        return result;
    }
}
