const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Config = struct {
    server: ServerConfig,
    authentication: AuthConfig,
    security: SecurityConfig,
    logging: LoggingConfig,
    performance: PerformanceConfig,
    data_dir: []const u8,
    schema_file: []const u8,
    schema_content: ?[]const u8 = null,
    authorization_file: ?[]const u8,
    allocator: Allocator,

    pub const ServerConfig = struct {
        port: u16 = 3000,
        host: []const u8 = "0.0.0.0",
    };

    pub const AuthConfig = struct {
        jwt_secret: ?[]const u8 = null,
        jwt_algorithm: []const u8,
        jwt_issuer: ?[]const u8 = null,
        jwt_audience: ?[]const u8 = null,
        jwt_jwks_url: ?[]const u8 = null,
        jwt_subject_claim: []const u8,
        ticket_secret: ?[]const u8 = null,
        ticket_ttl_seconds: u32 = 60,
        ticket_single_use: bool = true,
        anonymous_enabled: bool = false,
        anonymous_subject_prefix: []const u8,
        session: SessionConfig = .{},

        pub const SessionConfig = struct {
            claims: std.StringHashMapUnmanaged([]const u8) = .{},
            token_grace_period_seconds: u32 = 30,
        };
    };

    pub const SecurityConfig = struct {
        allowed_origins: []const []const u8 = &.{},
        allow_localhost: bool = true,
        max_messages_per_second: u32 = 100,
        max_connections: u32 = 100_000,
        violation_threshold: u32 = 10,
        max_message_size: usize = 1024 * 1024, // 1MB
    };

    pub const LoggingConfig = struct {
        level: LogLevel = .info,
        format: LogFormat = .json,

        pub const LogLevel = enum {
            debug,
            info,
            warn,
            @"error",
        };

        pub const LogFormat = enum {
            json,
            text,
        };
    };

    pub const PerformanceConfig = struct {
        message_buffer_size: usize = 1000,
        batch_writes: bool = true,
        batch_size: usize = 200,
        batch_timeout: u32 = 10,
        statement_cache_size: usize = 100,
    };

    pub fn deinit(self: *Config) void {
        // Free allocated strings
        if (self.authentication.jwt_secret) |secret| {
            self.allocator.free(secret);
        }
        self.allocator.free(self.authentication.jwt_algorithm);
        if (self.authentication.jwt_issuer) |issuer| {
            self.allocator.free(issuer);
        }
        if (self.authentication.jwt_audience) |audience| {
            self.allocator.free(audience);
        }
        if (self.authentication.jwt_jwks_url) |jwks_url| {
            self.allocator.free(jwks_url);
        }
        self.allocator.free(self.authentication.jwt_subject_claim);
        if (self.authentication.ticket_secret) |secret| {
            self.allocator.free(secret);
        }
        self.allocator.free(self.authentication.anonymous_subject_prefix);
        {
            var it = self.authentication.session.claims.iterator();
            while (it.next()) |entry| {
                self.allocator.free(entry.key_ptr.*);
                self.allocator.free(entry.value_ptr.*);
            }
            self.authentication.session.claims.deinit(self.allocator);
        }
        for (self.security.allowed_origins) |origin| {
            self.allocator.free(origin);
        }
        self.allocator.free(self.security.allowed_origins);
        self.allocator.free(self.server.host);
        self.allocator.free(self.data_dir);
        self.allocator.free(self.schema_file);
        if (self.schema_content) |content| { // Added deinit for schema_content
            self.allocator.free(content);
        }
        if (self.authorization_file) |file| {
            self.allocator.free(file);
        }
    }
};

pub const ConfigLoader = struct {
    pub fn load(allocator: Allocator, path: []const u8) !Config {
        // Try to read config file
        const file_content = std.fs.cwd().readFileAlloc(
            allocator,
            path,
            10 * 1024 * 1024, // 10MB max
        ) catch |err| {
            if (err == error.FileNotFound) {
                std.log.info("Config file not found, using defaults", .{});
                return loadDefaults(allocator);
            }
            return err;
        };
        defer allocator.free(file_content);

        // Substitute environment variables
        const substituted = try substituteEnvVars(allocator, file_content);
        defer allocator.free(substituted);

        // Parse JSON
        const parsed = try std.json.parseFromSlice(
            std.json.Value,
            allocator,
            substituted,
            .{},
        );
        defer parsed.deinit();

        // Build config from JSON
        var config = try buildConfig(allocator, parsed.value);
        errdefer config.deinit();

        // Validate config
        try validateConfig(&config);

        return config;
    }

    pub fn loadDefaults(allocator: Allocator) !Config {
        return Config{
            .server = .{
                .host = try allocator.dupe(u8, "0.0.0.0"),
            },
            .authentication = .{
                .jwt_algorithm = try allocator.dupe(u8, "HS256"),
                .jwt_subject_claim = try allocator.dupe(u8, "sub"),
                .anonymous_subject_prefix = try allocator.dupe(u8, "anon:"),
            },
            .security = .{},
            .logging = .{},
            .performance = .{},
            .data_dir = try allocator.dupe(u8, "./data"),
            .schema_file = try allocator.dupe(u8, "./schema.json"),
            .authorization_file = null,
            .allocator = allocator,
        };
    }

    fn substituteEnvVars(allocator: Allocator, content: []const u8) ![]const u8 {
        var result: std.ArrayListUnmanaged(u8) = .empty;
        errdefer result.deinit(allocator);

        var i: usize = 0;
        while (i < content.len) {
            // Look for ${VAR_NAME} pattern
            if (i + 2 < content.len and content[i] == '$' and content[i + 1] == '{') {
                // Find closing }
                const start = i + 2;
                var end = start;
                while (end < content.len and content[end] != '}') {
                    end += 1;
                }

                if (end < content.len) {
                    // Extract variable name
                    const var_name = content[start..end];

                    // Get environment variable
                    if (std.process.getEnvVarOwned(allocator, var_name)) |value| {
                        defer allocator.free(value);
                        try result.appendSlice(allocator, value);
                    } else |_| {
                        // Variable not found, keep original
                        try result.appendSlice(allocator, content[i .. end + 1]);
                    }

                    i = end + 1;
                    continue;
                }
            }

            try result.append(allocator, content[i]);
            i += 1;
        }

        return result.toOwnedSlice(allocator);
    }

    const json_access = @import("json_access.zig");

    fn buildConfig(allocator: Allocator, json: std.json.Value) !Config {
        var config = Config{
            .server = .{
                .host = try allocator.dupe(u8, "0.0.0.0"),
            },
            .authentication = .{
                .jwt_algorithm = try allocator.dupe(u8, "HS256"),
                .jwt_subject_claim = try allocator.dupe(u8, "sub"),
                .anonymous_subject_prefix = try allocator.dupe(u8, "anon:"),
            },
            .security = .{},
            .logging = .{},
            .performance = .{},
            .data_dir = try allocator.dupe(u8, "./data"),
            .schema_file = try allocator.dupe(u8, "./schema.json"),
            .authorization_file = null,
            .allocator = allocator,
        };
        errdefer config.deinit();

        if (json != .object) return error.InvalidConfigFormat;
        const obj = json.object;

        try parseServer(allocator, &config, obj);
        try parseAuthentication(allocator, &config, obj);
        try parseDataAndSchema(allocator, &config, obj);
        try parseSecurity(allocator, &config, obj);
        try parseLogging(allocator, &config, obj);
        try parsePerformance(allocator, &config, obj);

        return config;
    }

    fn parseServer(allocator: Allocator, config: *Config, obj: std.json.ObjectMap) !void {
        const server_obj = json_access.getObject(obj, "server") orelse return;
        if (json_access.getInt(server_obj, "port")) |port| {
            if (port < 0 or port > 65535) return error.InvalidPort;
            config.server.port = @intCast(port);
        }
        try json_access.replaceString(allocator, &config.server.host, server_obj, "host");
    }

    fn parseAuthentication(allocator: Allocator, config: *Config, obj: std.json.ObjectMap) !void {
        const auth_obj = json_access.getObject(obj, "authentication") orelse return;
        try parseAuthJwt(allocator, &config.authentication, auth_obj);
        try parseAuthTicket(allocator, &config.authentication, auth_obj);
        try parseAuthAnonymous(allocator, &config.authentication, auth_obj);
        try parseAuthSession(allocator, &config.authentication, auth_obj);
    }

    fn parseAuthJwt(allocator: Allocator, auth: *Config.AuthConfig, auth_obj: std.json.ObjectMap) !void {
        const jwt_obj = json_access.getObject(auth_obj, "jwt") orelse return;
        try json_access.setString(allocator, &auth.jwt_secret, jwt_obj, "secret");
        try json_access.replaceString(allocator, &auth.jwt_algorithm, jwt_obj, "algorithm");
        try json_access.setString(allocator, &auth.jwt_issuer, jwt_obj, "issuer");
        try json_access.setString(allocator, &auth.jwt_audience, jwt_obj, "audience");
        try json_access.setString(allocator, &auth.jwt_jwks_url, jwt_obj, "jwksUrl");
        try json_access.replaceString(allocator, &auth.jwt_subject_claim, jwt_obj, "subjectClaim");
    }

    fn parseAuthTicket(allocator: Allocator, auth: *Config.AuthConfig, auth_obj: std.json.ObjectMap) !void {
        const ticket_obj = json_access.getObject(auth_obj, "ticket") orelse return;
        try json_access.setString(allocator, &auth.ticket_secret, ticket_obj, "secret");
        if (json_access.getInt(ticket_obj, "ttlSeconds")) |ttl| {
            auth.ticket_ttl_seconds = @intCast(ttl);
        }
        if (json_access.getBool(ticket_obj, "singleUse")) |su| {
            auth.ticket_single_use = su;
        }
    }

    fn parseAuthAnonymous(allocator: Allocator, auth: *Config.AuthConfig, auth_obj: std.json.ObjectMap) !void {
        const anon_obj = json_access.getObject(auth_obj, "anonymous") orelse return;
        if (json_access.getBool(anon_obj, "enabled")) |enabled| {
            auth.anonymous_enabled = enabled;
        }
        try json_access.replaceString(allocator, &auth.anonymous_subject_prefix, anon_obj, "subjectPrefix");
    }

    fn parseAuthSession(allocator: Allocator, auth: *Config.AuthConfig, auth_obj: std.json.ObjectMap) !void {
        const session_obj = json_access.getObject(auth_obj, "session") orelse return;
        const claims_obj = json_access.getObject(session_obj, "claims") orelse return;
        var it = claims_obj.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.* != .string) continue;
            const jwt_claim = try allocator.dupe(u8, entry.key_ptr.*);
            errdefer allocator.free(jwt_claim);
            const session_var = try allocator.dupe(u8, entry.value_ptr.*.string);
            errdefer allocator.free(session_var);
            try auth.session.claims.put(allocator, jwt_claim, session_var);
        }
    }

    fn parseDataAndSchema(allocator: Allocator, config: *Config, obj: std.json.ObjectMap) !void {
        try json_access.replaceString(allocator, &config.data_dir, obj, "dataDir");

        if (obj.get("schema")) |schema_val| {
            switch (schema_val) {
                .string => |s| {
                    const new_schema_file = try allocator.dupe(u8, s);
                    allocator.free(config.schema_file);
                    config.schema_file = new_schema_file;
                },
                .object => |schema_obj| {
                    _ = schema_obj;
                    config.schema_content = try std.json.Stringify.valueAlloc(allocator, schema_val, .{});
                },
                else => {},
            }
        }

        try json_access.setString(allocator, &config.authorization_file, obj, "authorization");
    }

    fn parseSecurity(allocator: Allocator, config: *Config, obj: std.json.ObjectMap) !void {
        const security_obj = json_access.getObject(obj, "security") orelse return;

        if (json_access.getArray(security_obj, "allowedOrigins")) |origins| {
            var origin_list: std.ArrayListUnmanaged([]const u8) = .empty;
            errdefer {
                for (origin_list.items) |origin| {
                    allocator.free(origin);
                }
                origin_list.deinit(allocator);
            }
            for (origins.items) |origin| {
                if (origin == .string) {
                    const duped = try allocator.dupe(u8, origin.string);
                    errdefer allocator.free(duped);
                    try origin_list.append(allocator, duped);
                }
            }
            config.security.allowed_origins = try origin_list.toOwnedSlice(allocator);
        }

        if (json_access.getBool(security_obj, "allowLocalhost")) |v| {
            config.security.allow_localhost = v;
        }
        if (json_access.getInt(security_obj, "maxMessagesPerSecond")) |v| {
            config.security.max_messages_per_second = @intCast(v);
        }
        if (json_access.getInt(security_obj, "maxConnections")) |v| {
            config.security.max_connections = @intCast(v);
        }
        if (json_access.getInt(security_obj, "maxMessageSize")) |v| {
            config.security.max_message_size = @intCast(v);
        }
        if (json_access.getInt(security_obj, "violationThreshold")) |v| {
            config.security.violation_threshold = @intCast(v);
        }
    }

    fn parseLogging(allocator: Allocator, config: *Config, obj: std.json.ObjectMap) !void {
        _ = allocator;
        const logging_obj = json_access.getObject(obj, "logging") orelse return;

        if (json_access.getString(logging_obj, "level")) |level| {
            if (std.mem.eql(u8, level, "debug")) {
                config.logging.level = .debug;
            } else if (std.mem.eql(u8, level, "info")) {
                config.logging.level = .info;
            } else if (std.mem.eql(u8, level, "warn")) {
                config.logging.level = .warn;
            } else if (std.mem.eql(u8, level, "error")) {
                config.logging.level = .@"error";
            }
        }

        if (json_access.getString(logging_obj, "format")) |format| {
            if (std.mem.eql(u8, format, "json")) {
                config.logging.format = .json;
            } else if (std.mem.eql(u8, format, "text")) {
                config.logging.format = .text;
            }
        }
    }

    fn parsePerformance(allocator: Allocator, config: *Config, obj: std.json.ObjectMap) !void {
        _ = allocator;
        const perf_obj = json_access.getObject(obj, "performance") orelse return;

        if (json_access.getInt(perf_obj, "messageBufferSize")) |v| {
            config.performance.message_buffer_size = @intCast(v);
        }
        if (json_access.getBool(perf_obj, "batchWrites")) |v| {
            config.performance.batch_writes = v;
        }
        if (json_access.getInt(perf_obj, "batchSize")) |v| {
            config.performance.batch_size = @intCast(v);
        }
        if (json_access.getInt(perf_obj, "batchTimeout")) |v| {
            config.performance.batch_timeout = @intCast(v);
        }
        if (json_access.getInt(perf_obj, "statementCacheSize")) |v| {
            config.performance.statement_cache_size = @intCast(v);
        }
    }

    fn validateConfig(config: *Config) !void {
        // Validate port range
        if (config.server.port == 0 or config.server.port > 65535) {
            return error.InvalidPort;
        }

        // Validate data directory exists or can be created
        std.fs.cwd().makeDir(config.data_dir) catch |err| {
            if (err != error.PathAlreadyExists) {
                return error.InvalidDataDir;
            }
        };

        if (config.schema_content == null) {
            if (config.schema_file.len == 0) {
                return error.InvalidSchemaFile;
            }

            std.fs.cwd().access(config.schema_file, .{}) catch |err| {
                if (err != error.FileNotFound) return error.SchemaFileNotFound;
                std.log.info("Schema file not found, using implicit users-only schema", .{});
            };
        }

        // Validate authorization rules file exists if specified
        if (config.authorization_file) |auth_file| {
            std.fs.cwd().access(auth_file, .{}) catch {
                return error.AuthRulesFileNotFound;
            };
        }

        // Validate numeric ranges
        if (config.performance.message_buffer_size == 0) {
            return error.InvalidBufferSize;
        }

        if (config.performance.batch_size == 0) {
            return error.InvalidBatchSize;
        }

        if (config.performance.statement_cache_size == 0) {
            return error.InvalidStatementCacheSize;
        }

        if (config.security.max_message_size == 0) {
            return error.InvalidMaxMessageSize;
        }
    }
};
