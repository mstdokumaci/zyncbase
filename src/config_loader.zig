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

        if (json != .object) {
            return error.InvalidConfigFormat;
        }

        const obj = json.object;

        // Parse server config
        if (obj.get("server")) |server_json| {
            if (server_json == .object) {
                const server_obj = server_json.object;

                if (server_obj.get("port")) |port| {
                    if (port == .integer) {
                        if (port.integer < 0 or port.integer > 65535) {
                            return error.InvalidPort;
                        }
                        config.server.port = @intCast(port.integer);
                    }
                }

                if (server_obj.get("host")) |host| {
                    if (host == .string) {
                        const new_host = try allocator.dupe(u8, host.string);
                        allocator.free(config.server.host);
                        config.server.host = new_host;
                    }
                }
            }
        }

        // Parse authentication config
        if (obj.get("authentication")) |auth_json| {
            if (auth_json == .object) {
                const auth_obj = auth_json.object;

                if (auth_obj.get("jwt")) |jwt_json| {
                    if (jwt_json == .object) {
                        const jwt_obj = jwt_json.object;

                        if (jwt_obj.get("secret")) |secret| {
                            if (secret == .string) {
                                config.authentication.jwt_secret = try allocator.dupe(u8, secret.string);
                            }
                        }

                        if (jwt_obj.get("algorithm")) |algo| {
                            if (algo == .string) {
                                const new_algo = try allocator.dupe(u8, algo.string);
                                allocator.free(config.authentication.jwt_algorithm);
                                config.authentication.jwt_algorithm = new_algo;
                            }
                        }

                        if (jwt_obj.get("issuer")) |issuer| {
                            if (issuer == .string) {
                                config.authentication.jwt_issuer = try allocator.dupe(u8, issuer.string);
                            }
                        }

                        if (jwt_obj.get("audience")) |audience| {
                            if (audience == .string) {
                                config.authentication.jwt_audience = try allocator.dupe(u8, audience.string);
                            }
                        }

                        if (jwt_obj.get("jwksUrl")) |jwks| {
                            if (jwks == .string) {
                                config.authentication.jwt_jwks_url = try allocator.dupe(u8, jwks.string);
                            }
                        }

                        if (jwt_obj.get("subjectClaim")) |sub| {
                            if (sub == .string) {
                                const new_sub = try allocator.dupe(u8, sub.string);
                                allocator.free(config.authentication.jwt_subject_claim);
                                config.authentication.jwt_subject_claim = new_sub;
                            }
                        }
                    }
                }

                if (auth_obj.get("ticket")) |ticket_json| {
                    if (ticket_json == .object) {
                        const ticket_obj = ticket_json.object;

                        if (ticket_obj.get("secret")) |secret| {
                            if (secret == .string) {
                                config.authentication.ticket_secret = try allocator.dupe(u8, secret.string);
                            }
                        }

                        if (ticket_obj.get("ttlSeconds")) |ttl| {
                            if (ttl == .integer) {
                                config.authentication.ticket_ttl_seconds = @intCast(ttl.integer);
                            }
                        }

                        if (ticket_obj.get("singleUse")) |su| {
                            if (su == .bool) {
                                config.authentication.ticket_single_use = su.bool;
                            }
                        }
                    }
                }

                if (auth_obj.get("anonymous")) |anon_json| {
                    if (anon_json == .object) {
                        const anon_obj = anon_json.object;

                        if (anon_obj.get("enabled")) |enabled| {
                            if (enabled == .bool) {
                                config.authentication.anonymous_enabled = enabled.bool;
                            }
                        }

                        if (anon_obj.get("subjectPrefix")) |prefix| {
                            if (prefix == .string) {
                                const new_prefix = try allocator.dupe(u8, prefix.string);
                                allocator.free(config.authentication.anonymous_subject_prefix);
                                config.authentication.anonymous_subject_prefix = new_prefix;
                            }
                        }
                    }
                }

                if (auth_obj.get("session")) |session_json| {
                    if (session_json == .object) {
                        const session_obj = session_json.object;

                        if (session_obj.get("claims")) |claims_json| {
                            if (claims_json == .object) {
                                const claims_obj = claims_json.object;
                                var it = claims_obj.iterator();
                                while (it.next()) |entry| {
                                    if (entry.value_ptr.* == .string) {
                                        const jwt_claim = try allocator.dupe(u8, entry.key_ptr.*);
                                        errdefer allocator.free(jwt_claim);
                                        const session_var = try allocator.dupe(u8, entry.value_ptr.*.string);
                                        errdefer allocator.free(session_var);
                                        try config.authentication.session.claims.put(allocator, jwt_claim, session_var);
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }

        // Parse data directory
        if (obj.get("dataDir")) |data_dir| {
            if (data_dir == .string) {
                const new_data_dir = try allocator.dupe(u8, data_dir.string);
                allocator.free(config.data_dir);
                config.data_dir = new_data_dir;
            }
        }

        // Parse schema file
        if (obj.get("schema")) |schema| {
            if (schema == .string) {
                const new_schema_file = try allocator.dupe(u8, schema.string);
                allocator.free(config.schema_file);
                config.schema_file = new_schema_file;
            } else if (schema == .object) {
                config.schema_content = try std.json.Stringify.valueAlloc(allocator, schema, .{});
            }
        }

        // Parse authorization rules file
        if (obj.get("authorization")) |auth_rules| {
            if (auth_rules == .string) {
                config.authorization_file = try allocator.dupe(u8, auth_rules.string);
            }
        }

        // Parse security config
        if (obj.get("security")) |security_json| {
            if (security_json == .object) {
                const security_obj = security_json.object;

                if (security_obj.get("allowedOrigins")) |origins| {
                    if (origins == .array) {
                        var origin_list: std.ArrayListUnmanaged([]const u8) = .empty;
                        for (origins.array.items) |origin| {
                            if (origin == .string) {
                                try origin_list.append(allocator, try allocator.dupe(u8, origin.string));
                            }
                        }
                        config.security.allowed_origins = try origin_list.toOwnedSlice(allocator);
                    }
                }

                if (security_obj.get("allowLocalhost")) |allow_localhost| {
                    if (allow_localhost == .bool) {
                        config.security.allow_localhost = allow_localhost.bool;
                    }
                }

                if (security_obj.get("maxMessagesPerSecond")) |limit| {
                    if (limit == .integer) {
                        config.security.max_messages_per_second = @intCast(limit.integer);
                    }
                }

                if (security_obj.get("maxConnections")) |limit| {
                    if (limit == .integer) {
                        config.security.max_connections = @intCast(limit.integer);
                    }
                }

                if (security_obj.get("maxMessageSize")) |size| {
                    if (size == .integer) {
                        config.security.max_message_size = @intCast(size.integer);
                    }
                }

                if (security_obj.get("violationThreshold")) |threshold| {
                    if (threshold == .integer) {
                        config.security.violation_threshold = @intCast(threshold.integer);
                    }
                }
            }
        }

        // Parse logging config
        if (obj.get("logging")) |logging_json| {
            if (logging_json == .object) {
                const logging_obj = logging_json.object;

                if (logging_obj.get("level")) |level| {
                    if (level == .string) {
                        if (std.mem.eql(u8, level.string, "debug")) {
                            config.logging.level = .debug;
                        } else if (std.mem.eql(u8, level.string, "info")) {
                            config.logging.level = .info;
                        } else if (std.mem.eql(u8, level.string, "warn")) {
                            config.logging.level = .warn;
                        } else if (std.mem.eql(u8, level.string, "error")) {
                            config.logging.level = .@"error";
                        }
                    }
                }

                if (logging_obj.get("format")) |format| {
                    if (format == .string) {
                        if (std.mem.eql(u8, format.string, "json")) {
                            config.logging.format = .json;
                        } else if (std.mem.eql(u8, format.string, "text")) {
                            config.logging.format = .text;
                        }
                    }
                }
            }
        }

        // Parse performance config
        if (obj.get("performance")) |performance_json| {
            if (performance_json == .object) {
                const performance_obj = performance_json.object;

                if (performance_obj.get("messageBufferSize")) |buffer_size| {
                    if (buffer_size == .integer) {
                        config.performance.message_buffer_size = @intCast(buffer_size.integer);
                    }
                }

                if (performance_obj.get("batchWrites")) |batch_writes| {
                    if (batch_writes == .bool) {
                        config.performance.batch_writes = batch_writes.bool;
                    }
                }

                if (performance_obj.get("batchSize")) |batch_size| {
                    if (batch_size == .integer) {
                        config.performance.batch_size = @intCast(batch_size.integer);
                    }
                }

                if (performance_obj.get("batchTimeout")) |batch_timeout| {
                    if (batch_timeout == .integer) {
                        config.performance.batch_timeout = @intCast(batch_timeout.integer);
                    }
                }
                if (performance_obj.get("statementCacheSize")) |cache_size| {
                    if (cache_size == .integer) {
                        config.performance.statement_cache_size = @intCast(cache_size.integer);
                    }
                }
            }
        }

        return config;
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
