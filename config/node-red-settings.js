/**
 * Node-RED Settings Configuration
 * Deployed to /var/lib/node-red/settings.js by NixOS
 *
 * Security Features:
 * - adminAuth: Username/password authentication for editor and Admin API
 * - httpNodeAuth: Bearer token authentication for HTTP nodes (API endpoints)
 * - Credentials stored in SOPS and loaded from /run/secrets/
 */

const fs = require('fs');
const path = require('path');

/**
 * Load secrets from SOPS-deployed files
 * These files are created by the SOPS service and mounted into /run/secrets/
 */
function loadSecret(secretPath) {
    try {
        return fs.readFileSync(secretPath, 'utf8').trim();
    } catch (error) {
        console.error(`Failed to load secret from ${secretPath}:`, error.message);
        return null;
    }
}

function loadJsonSecret(secretPath) {
    try {
        const content = fs.readFileSync(secretPath, 'utf8');
        return JSON.parse(content);
    } catch (error) {
        console.error(`Failed to load JSON secret from ${secretPath}:`, error.message);
        return null;
    }
}

// Load authentication secrets
const adminUsername = loadSecret('/run/secrets/node-red/admin-username') || 'admin';
const adminPasswordHash = loadSecret('/run/secrets/node-red/admin-password-hash');
const apiTokens = loadJsonSecret('/run/secrets/node-red/api-tokens') || [];

// Validate that required secrets are available
if (!adminPasswordHash) {
    console.error('CRITICAL: Admin password hash not found! Node-RED admin interface will be INSECURE.');
}

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
    adminAuth: adminPasswordHash ? {
        type: "credentials",
        users: [{
            username: adminUsername,
            password: adminPasswordHash,
            permissions: "*"
        }],
        // Tokens expire after 7 days of inactivity
        sessionExpiryTime: 604800
    } : undefined,

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
    uiPort: process.env.PORT || 1880,
    uiHost: "127.0.0.1", // Only listen on localhost (nginx proxies from outside)

    /**
     * Node Settings
     */
    functionGlobalContext: {
        // Global context available to function nodes
    },

    /**
     * Logging Configuration
     */
    logging: {
        console: {
            level: "info",
            metrics: false,
            audit: false
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

    // Content Security Policy
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
