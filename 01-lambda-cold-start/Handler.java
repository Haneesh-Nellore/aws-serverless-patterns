package com.serverless.patterns;

import com.amazonaws.services.lambda.runtime.Context;
import com.amazonaws.services.lambda.runtime.RequestHandler;
import software.amazon.awssdk.services.secretsmanager.SecretsManagerClient;
import software.amazon.awssdk.services.secretsmanager.model.GetSecretValueRequest;

import java.sql.Connection;
import java.sql.DriverManager;
import java.sql.PreparedStatement;
import java.sql.ResultSet;
import java.util.HashMap;
import java.util.Map;

/**
 * Lambda Cold Start Optimization Pattern
 *
 * Key principle: Move expensive initialization OUTSIDE the handler method.
 * Code outside the handler runs once per container lifecycle (cold start only).
 * Code inside the handler runs on every invocation.
 *
 * This pattern reduced p99 latency to under 200ms on user-facing endpoints
 * after migrating from Kubernetes to Lambda.
 */
public class Handler implements RequestHandler<Map<String, String>, Map<String, Object>> {

    // ✅ Initialized ONCE per container — not on every invocation
    private static final SecretsManagerClient secretsClient;
    private static final Connection dbConnection;
    private static final String DB_URL;

    static {
        // Static block runs once when the container starts (cold start)
        // All subsequent invocations reuse these resources

        secretsClient = SecretsManagerClient.builder().build();

        // Fetch DB credentials from Secrets Manager at init time
        String secret = secretsClient.getSecretValue(
            GetSecretValueRequest.builder()
                .secretId(System.getenv("DB_SECRET_ARN"))
                .build()
        ).secretString();

        DB_URL = parseDbUrl(secret);

        try {
            // Connection pooling: single connection reused across warm invocations
            // For high concurrency, use RDS Proxy instead (see 04-concurrency/)
            dbConnection = DriverManager.getConnection(DB_URL);
        } catch (Exception e) {
            throw new RuntimeException("Failed to initialize DB connection at cold start", e);
        }

        System.out.println("Cold start initialization complete");
    }

    @Override
    public Map<String, Object> handleRequest(Map<String, String> event, Context context) {
        Map<String, Object> response = new HashMap<>();

        try {
            String userId = event.get("userId");

            if (userId == null || userId.isEmpty()) {
                response.put("statusCode", 400);
                response.put("body", "userId is required");
                return response;
            }

            // ✅ dbConnection already exists — no init cost here
            String result = queryUser(userId);

            response.put("statusCode", 200);
            response.put("body", result);

        } catch (Exception e) {
            System.err.println("Handler error: " + e.getMessage());
            response.put("statusCode", 500);
            response.put("body", "Internal server error");
        }

        return response;
    }

    private String queryUser(String userId) throws Exception {
        String sql = "SELECT name, email FROM users WHERE id = ?";

        try (PreparedStatement stmt = dbConnection.prepareStatement(sql)) {
            stmt.setString(1, userId);
            ResultSet rs = stmt.executeQuery();

            if (rs.next()) {
                return String.format("{\"name\": \"%s\", \"email\": \"%s\"}",
                    rs.getString("name"),
                    rs.getString("email"));
            }
            return "{\"error\": \"User not found\"}";
        }
    }

    private static String parseDbUrl(String secretJson) {
        // Parse the JSON secret to build JDBC URL
        // In production, use Jackson or Gson for proper JSON parsing
        // Simplified here for clarity
        return "jdbc:postgresql://your-db-host:5432/yourdb";
    }
}

