import javax.crypto.Cipher;
import javax.crypto.spec.SecretKeySpec;
import java.nio.charset.StandardCharsets;
import java.util.Base64;

/**
 * 运维本地工具：生成子台部署用的 MASTER_ENDPOINT_ENC 密文（算法与后端 MasterEndpointCrypto 一致）。
 *
 * 用法:
 *   javac scripts/EncryptMasterEndpoint.java
 *   java -cp scripts EncryptMasterEndpoint --url https://master.example/prod-api --api-key YOUR_KEY [--ssl-insecure]
 */
public class EncryptMasterEndpoint {

    private static final String ALGORITHM = "AES/ECB/PKCS5Padding";
    private static final String AES_KEY = "TK_Master#2026!!";

    public static void main(String[] args) throws Exception {
        String url = null;
        String apiKey = null;
        boolean sslInsecure = false;
        for (int i = 0; i < args.length; i++) {
            switch (args[i]) {
                case "--url":
                    url = args[++i];
                    break;
                case "--api-key":
                    apiKey = args[++i];
                    break;
                case "--ssl-insecure":
                    sslInsecure = true;
                    break;
                default:
                    System.err.println("未知参数: " + args[i]);
                    System.exit(2);
            }
        }
        if (url == null || apiKey == null) {
            System.err.println("用法: java EncryptMasterEndpoint --url <总台URL> --api-key <密钥> [--ssl-insecure]");
            System.exit(2);
        }
        while (url.endsWith("/")) {
            url = url.substring(0, url.length() - 1);
        }
        String json = String.format(
                "{\"v\":1,\"url\":\"%s\",\"apiKey\":\"%s\",\"sslInsecure\":%s}",
                escapeJson(url), escapeJson(apiKey), sslInsecure);
        String cipher = encrypt(json, AES_KEY);
        System.out.println(cipher);
    }

    private static String escapeJson(String s) {
        return s.replace("\\", "\\\\").replace("\"", "\\\"");
    }

    private static String encrypt(String data, String key) throws Exception {
        byte[] keyBytes = key.getBytes(StandardCharsets.UTF_8);
        SecretKeySpec secretKey = new SecretKeySpec(keyBytes, "AES");
        Cipher cipher = Cipher.getInstance(ALGORITHM);
        cipher.init(Cipher.ENCRYPT_MODE, secretKey);
        byte[] cipherText = cipher.doFinal(data.getBytes(StandardCharsets.UTF_8));
        return Base64.getEncoder().encodeToString(cipherText);
    }
}
