/**
 * Node-RED Settings Configuration
 * Copied into the Nix store by modules/services/node-red.nix and passed to
 * node-red as `--settings <store path>`; it is NOT written to
 * /var/lib/node-red/settings.js (that path stays the userDir only).
 *
 * Security Features:
 * - adminAuth: Username/password authentication for editor and Admin API
 * - httpNodeMiddleware: Bearer token authentication for HTTP nodes (API endpoints)
 * - Credentials stored in SOPS and loaded from /run/secrets/
 */

const fs = require('fs');

const ADMIN_PASSWORD_DIAGNOSTIC =
    'CRITICAL: Node-RED admin password secret is unavailable or invalid.';
const API_TOKENS_DIAGNOSTIC =
    'CRITICAL: Node-RED API token secret is unavailable or invalid.';
const BCRYPT_HASH = /^\$2[aby]\$(?:0[4-9]|[12][0-9]|3[01])\$[./A-Za-z0-9]{53}$/;

/**
 * Load secrets from SOPS-deployed files
 * These files are created by sops-nix during system activation (there is no
 * sops-install-secrets.service on this host) and appear under /run/secrets/
 */
function failStartup(diagnostic) {
    console.error(diagnostic);
    throw new Error(diagnostic);
}

function loadOptionalSecret(secretPath) {
    try {
        return fs.readFileSync(secretPath, 'utf8').trim();
    } catch {
        return null;
    }
}

function loadAdminPassword(secretPath) {
    let value;
    try {
        value = fs.readFileSync(secretPath, 'utf8');
    } catch {
        failStartup(ADMIN_PASSWORD_DIAGNOSTIC);
    }
    if (value.endsWith('\n')) {
        value = value.slice(0, -1);
    }
    if (!BCRYPT_HASH.test(value)) {
        failStartup(ADMIN_PASSWORD_DIAGNOSTIC);
    }
    return value;
}

function loadApiTokens(secretPath) {
    let value;
    try {
        value = JSON.parse(fs.readFileSync(secretPath, 'utf8'));
    } catch {
        failStartup(API_TOKENS_DIAGNOSTIC);
    }
    if (!Array.isArray(value) || !value.every(entry =>
        entry !== null &&
        typeof entry === 'object' &&
        !Array.isArray(entry) &&
        typeof entry.token === 'string' &&
        entry.token.length > 0
    )) {
        failStartup(API_TOKENS_DIAGNOSTIC);
    }
    return value;
}

// Load authentication secrets
const adminUsername = loadOptionalSecret('/run/secrets/node-red/admin-username') || 'admin';
const adminPasswordHash = loadAdminPassword('/run/secrets/node-red/admin-password-hash');
const apiTokens = loadApiTokens('/run/secrets/node-red/api-tokens');

if (apiTokens.length === 0) {
    console.warn('WARNING: No API tokens configured. HTTP nodes will only accept basic auth.');
}

/**
 * Main Node-RED configuration
 */
module.exports = {
    /**
     * Admin Authentication
     * Secures the Node-RED editor and Admin API
     * Users must log in with username/password to access the editor
     */
    adminAuth: {
        type: "credentials",
        users: [{
            username: adminUsername,
            password: adminPasswordHash,
            permissions: "*"
        }],
        // Editor login sessions expire 7 days after login. Node-RED sets the
        // expiry once at session creation (editor-api auth/tokens.js) and does
        // not extend it on use, so this is an absolute lifetime, not an
        // inactivity timeout. Does not apply to the service tokens below.
        sessionExpiryTime: 604800,
        // Service tokens: same SOPS-managed tokens used by httpNodeMiddleware
        // also authorize the Admin API, with full permissions. Local flow
        // automation uses the host-owned node-red-admin helper so callers do
        // not handle this service token directly. Other HTTP-node consumers
        // continue to use their separately scoped bearer-token files.
        tokens: async function (token) {
            if (apiTokens.some(t => t.token === token)) {
                return { username: "service", permissions: "*" };
            }
            return null;
        }
    },

    /**
     * HTTP Node Middleware
     * Secures all HTTP endpoints created with HTTP In nodes
     * Supports Bearer Token authentication
     *
     * Bearer Token Format: Authorization: Bearer <token>
     *
     * Exceptions:
     * - /metrics: Prometheus metrics endpoint (requires bearer token via Prometheus config)
     */
    httpNodeMiddleware: function(req, res, next) {
        // Allow /metrics endpoint for Prometheus scraping
        // Prometheus provides bearer token in its request
        if (req.path === '/metrics') {
            const authHeader = req.headers.authorization;

            // Prometheus must provide a valid bearer token
            if (authHeader && authHeader.startsWith('Bearer ')) {
                const token = authHeader.substring(7);
                const validToken = apiTokens.some(t => t.token === token);

                if (validToken) {
                    return next();
                }
            }

            // If /metrics accessed without valid token, return 401
            res.status(401).json({
                error: 'Unauthorized',
                message: 'Valid bearer token required for metrics endpoint'
            });
            return;
        }

        // For all other HTTP nodes, require bearer token
        const authHeader = req.headers.authorization;

        // Check for Bearer token
        if (authHeader && authHeader.startsWith('Bearer ')) {
            const token = authHeader.substring(7);
            const validToken = apiTokens.some(t => t.token === token);

            if (validToken) {
                return next();
            }
        }

        // If no valid token, return 401
        res.status(401).json({
            error: 'Unauthorized',
            message: 'Valid bearer token required. Use: Authorization: Bearer <token>'
        });
    },

    /**
     * Editor UI Settings
     */
    // Keep the fallback on the privileged loopback listener if PORT is absent.
    uiPort: process.env.PORT || 844,
    uiHost: "127.0.0.1", // Only listen on localhost (nginx proxies from outside)

    /**
     * Node Settings
     */
    functionGlobalContext: {
        // Global context available to function nodes
    },

    /**
     * Logging Configuration
     *
     * console:  human-readable info to journalctl/stdout
     * dbAudit:  every audit event (deploys, edits, nodes installed, runtime errors)
     *           is written to PostgreSQL nodered_events.audit_events.
     *           Hook-level message tracing is handled by the event-logger plugin.
     */
    logging: {
        console: {
            level: "info",
            metrics: false,
            audit: false
        },
        dbAudit: {
            level: "info",
            metrics: false,
            audit: true,
            // NODE_PATH is set to /var/lib/node-red/node_modules in the
            // node-red service unit (see node-red-event-logger.nix), which
            // lets this bare-name require resolve even though settings.js
            // is loaded out of /nix/store.
            handler: function(/* settings */) {
                const { Pool } = require('pg');
                const pool = new Pool({
                    host: '/run/postgresql',
                    database: 'nodered_events',
                });
                pool.on('error', (err) => console.error('[audit] pg error:', err.message));
                return function(msg) {
                    const txt = typeof msg.msg === 'object'
                        ? JSON.stringify(msg.msg)
                        : (msg.msg == null ? null : String(msg.msg));
                    pool.query(
                        `INSERT INTO audit_events (level, type, event, name, node_id, msg, "user")
                         VALUES ($1,$2,$3,$4,$5,$6,$7)`,
                        [msg.level, msg.type || null, msg.event || null, msg.name || null,
                         msg.id || null, txt, (msg.user && msg.user.username) || null]
                    ).catch(e => console.error('[audit] insert failed:', e.message));
                };
            }
        }
    },

    /**
     * Editor Settings
     */
    editorTheme: {
        projects: {
            enabled: false
        },
        palette: {
            editable: true // Allow installing nodes via palette manager
        }
    },

    /**
     * Security Settings
     */

    // Require HTTPS for editor (handled by nginx proxy)
    requireHttps: false, // nginx handles SSL termination

    // Cross-Origin Resource Sharing for HTTP-In endpoints (not a CSP)
    httpNodeCors: {
        origin: "*",
        methods: "GET,PUT,POST,DELETE"
    },

    /**
     * Function Node Settings
     */
    functionExternalModules: true, // Allow requiring external modules in function nodes

    /**
     * Debug Settings
     */
    debugMaxLength: 1000,

    /**
     * Flow File Settings
     */
    flowFile: 'flows.json',
    flowFilePretty: true,

    /**
     * Context Storage
     */
    contextStorage: {
        default: {
            module: "localfilesystem"
        }
    }
};
