import java.io.ByteArrayInputStream;
import java.security.*;
import java.security.cert.Certificate;
import java.util.Arrays;
import java.util.Base64;
import java.util.HexFormat;

/** CI-only proof of the existing owner's key. Never writes key material. */
class CheckUpgradeSigner {
    static final String EXPECTED = "c8e89c07b45ed7789cf2e5484180a7d423d2a5e2040e1ac2a4192f0f14d1eb52";
    static String env(String name) {
        String value = System.getenv(name);
        if (value == null || value.isBlank()) throw new IllegalStateException("MISSING_" + name);
        return value;
    }
    public static void main(String[] args) {
        byte[] encoded = null;
        char[] storePassword = null, keyPassword = null;
        try {
            encoded = Base64.getMimeDecoder().decode(env("PALA_F1_KEYSTORE_BASE64"));
            storePassword = env("PALA_F1_KEYSTORE_PASSWORD").toCharArray();
            keyPassword = env("PALA_F1_KEY_PASSWORD").toCharArray();
            String alias = env("PALA_F1_KEY_ALIAS");
            KeyStore store = KeyStore.getInstance("PKCS12");
            store.load(new ByteArrayInputStream(encoded), storePassword);
            if (!store.isKeyEntry(alias)) throw new IllegalStateException("PRIVATE_KEY_ENTRY_MISSING");
            Key key = store.getKey(alias, keyPassword);
            if (!(key instanceof PrivateKey)) throw new IllegalStateException("PRIVATE_KEY_MISSING");
            Certificate certificate = store.getCertificate(alias);
            String fingerprint = HexFormat.of().formatHex(MessageDigest.getInstance("SHA-256").digest(certificate.getEncoded()));
            if (!EXPECTED.equals(fingerprint)) throw new IllegalStateException("OWNER_CERTIFICATE_MISMATCH");
            String algorithm = switch (key.getAlgorithm()) {
                case "RSA" -> "SHA256withRSA";
                case "EC" -> "SHA256withECDSA";
                default -> throw new IllegalStateException("UNSUPPORTED_SIGNING_KEY");
            };
            byte[] challenge = new byte[32];
            new SecureRandom().nextBytes(challenge);
            Signature signer = Signature.getInstance(algorithm);
            signer.initSign((PrivateKey) key);
            signer.update(challenge);
            byte[] signed = signer.sign();
            Signature verifier = Signature.getInstance(algorithm);
            verifier.initVerify(certificate);
            verifier.update(challenge);
            if (!verifier.verify(signed)) throw new IllegalStateException("PRIVATE_KEY_PROOF_FAILED");
            System.out.println("{\"status\":\"PASS\",\"owner_key_usable\":true,\"certificate_sha256\":\"" + fingerprint + "\",\"reference_package\":\"ir.pardis.ai.pala.f1diag2\",\"reference_version_code\":5,\"reference_apk_sha256\":\"9f6e58baa4ece1a4883a8ce6c2bd4e96e1aa3ed707fd9038cfc69736c3286b66\",\"live_device_certificate\":\"NOT_VERIFIED_DEVICE_NOT_CONNECTED\"}");
        } catch (Exception error) {
            // Fixed validation reasons only; never print a provider/keystore exception.
            String reason = error instanceof IllegalStateException ? error.getMessage() : error.getClass().getSimpleName();
            System.err.println("SIGNING_PREFLIGHT_FAILED:" + reason);
            System.exit(1);
        } finally {
            if (encoded != null) Arrays.fill(encoded, (byte) 0);
            if (storePassword != null) Arrays.fill(storePassword, '\0');
            if (keyPassword != null) Arrays.fill(keyPassword, '\0');
        }
    }
}
