import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.security.KeyFactory;
import java.security.PrivateKey;
import java.security.Signature;
import java.security.spec.PKCS8EncodedKeySpec;
import java.time.Instant;
import java.time.temporal.ChronoUnit;
import java.util.Base64;

/**
 * 运维本地签名工具（私钥勿提交 Git）。
 *
 * 用法:
 *   javac -d scripts/.build scripts/SignMasterEndpoint.java
 *   java -cp scripts/.build SignMasterEndpoint \
 *     --private-key scripts/keys/master-sign-private.pem \
 *     --url https://master.example/prod-api \
 *     --api-key YOUR_KEY \
 *     [--ssl-insecure] [--days 365]
 */
public class SignMasterEndpoint {

    public static void main(String[] args) throws Exception {
        String privateKeyPath = null;
        String url = null;
        String apiKey = null;
        boolean sslInsecure = false;
        int days = 365;

        for (int i = 0; i < args.length; i++) {
            switch (args[i]) {
                case "--private-key":
                    privateKeyPath = args[++i];
                    break;
                case "--url":
                    url = args[++i];
                    break;
                case "--api-key":
                    apiKey = args[++i];
                    break;
                case "--ssl-insecure":
                    sslInsecure = true;
                    break;
                case "--days":
                    days = Integer.parseInt(args[++i]);
                    break;
                default:
                    System.err.println("未知参数: " + args[i]);
                    System.exit(2);
            }
        }
        if (privateKeyPath == null || url == null || apiKey == null) {
            System.err.println("用法: SignMasterEndpoint --private-key <pem> --url <url> --api-key <key> [--ssl-insecure] [--days 90]");
            System.exit(2);
        }
        while (url.endsWith("/")) {
            url = url.substring(0, url.length() - 1);
        }
        long exp = Instant.now().plus(days, ChronoUnit.DAYS).getEpochSecond();
        String json = String.format(
                "{\"v\":2,\"url\":\"%s\",\"apiKey\":\"%s\",\"sslInsecure\":%s,\"exp\":%d,\"kid\":\"default\"}",
                escapeJson(url), escapeJson(apiKey), sslInsecure, exp);

        byte[] payload = json.getBytes(StandardCharsets.UTF_8);
        PrivateKey privateKey = loadPrivateKey(Path.of(privateKeyPath));
        byte[] signature = sign(privateKey, payload);

        String pkg = "v2." + base64UrlEncode(payload) + "." + base64UrlEncode(signature);
        System.out.println(pkg);
    }

    private static String escapeJson(String s) {
        return s.replace("\\", "\\\\").replace("\"", "\\\"");
    }

    private static PrivateKey loadPrivateKey(Path path) throws Exception {
        String pem = Files.readString(path);
        pem = pem.replace("-----BEGIN RSA PRIVATE KEY-----", "")
                .replace("-----END RSA PRIVATE KEY-----", "")
                .replace("-----BEGIN PRIVATE KEY-----", "")
                .replace("-----END PRIVATE KEY-----", "")
                .replaceAll("\\s", "");
        byte[] encoded = Base64.getDecoder().decode(pem);
        PKCS8EncodedKeySpec spec = new PKCS8EncodedKeySpec(encoded);
        try {
            return KeyFactory.getInstance("RSA").generatePrivate(spec);
        } catch (Exception e) {
            // openssl genrsa 默认 PKCS#1，需转换；此处用 BC 风格再试
            return KeyFactory.getInstance("RSA").generatePrivate(new PKCS8EncodedKeySpec(
                    convertPkcs1ToPkcs8(encoded)));
        }
    }

    /** 简易 PKCS#1 → PKCS#8 包装（仅用于 openssl genrsa 生成的传统密钥） */
    private static byte[] convertPkcs1ToPkcs8(byte[] pkcs1) {
        byte[] header = new byte[] {
                0x30, (byte) 0x82, 0, 0, 0x02, 0x01, 0x00, 0x30, 0x0d, 0x06, 0x09, 0x2a,
                (byte) 0x86, 0x48, (byte) 0x86, (byte) 0xf7, 0x0d, 0x01, 0x01, 0x01, 0x05, 0x00, 0x04, (byte) 0x82, 0, 0
        };
        int total = header.length + pkcs1.length;
        byte[] result = new byte[total];
        System.arraycopy(header, 0, result, 0, header.length);
        System.arraycopy(pkcs1, 0, result, header.length, pkcs1.length);
        int len = pkcs1.length;
        result[2] = (byte) ((len + 22) >> 8);
        result[3] = (byte) (len + 22);
        result[header.length - 2] = (byte) (len >> 8);
        result[header.length - 1] = (byte) len;
        return result;
    }

    private static byte[] sign(PrivateKey key, byte[] payload) throws Exception {
        Signature signer = Signature.getInstance("SHA256withRSA");
        signer.initSign(key);
        signer.update(payload);
        return signer.sign();
    }

    private static String base64UrlEncode(byte[] data) {
        return Base64.getUrlEncoder().withoutPadding().encodeToString(data);
    }
}
