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

    const ServerConfig = struct {
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
        anonymous_enabled: bool = false,
        anonymous_subject_prefix: []const u8,
        session: SessionConfig = .{},

        const SessionConfig = struct {
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
        batch_size: usize = 500,
        batch_timeout: u32 = 8,
        statement_cache_size: usize = 100,
    };

    pub fn deinit(self: *Config) void {
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
        if (self.schema_content) |content| {
            self.allocator.free(content);
        }
        if (self.authorization_file) |file| {
            self.allocator.free(file);
        }
    }
};
