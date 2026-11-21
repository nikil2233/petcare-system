// DEVELOPMENT ONLY: gives the seed users (placeholder passwords) a real password for testing.
require('dotenv').config();
const bcrypt = require('bcryptjs');
const pool = require('../src/db');

if (process.env.NODE_ENV === 'production') {
  console.error('Never run this in production');
  process.exit(1);
}

const password = process.argv[2];
if (!password || password.length < 8) {
  console.error('Usage: node scripts/set-dev-passwords.js <password with 8+ characters>');
  process.exit(1);
}

(async () => {
  const hash = await bcrypt.hash(password, 10);
  // Only touches seed users that still have the placeholder, so your real test account is safe.
  const { rowCount } = await pool.query(
    `UPDATE users SET password_hash = $1
      WHERE email LIKE '%@example.com' AND password_hash = 'placeholder-hash'`,
    [hash]
  );
  console.log(`Updated ${rowCount} seed users`);
  await pool.end();
})();