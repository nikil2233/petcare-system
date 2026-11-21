const express = require('express');
const pool = require('../db');
const requireAuth = require('../middleware/requireAuth');
const requireRole = require('../middleware/requireRole');

const router = express.Router();
router.use(requireAuth, requireRole('owner'));

const isText = (v) => typeof v === 'string' && v.trim().length > 0;
const textOrNull = (v) => (isText(v) ? v.trim() : null);

// See my own details
router.get('/', async (req, res) => {
  try {
    const { rows } = await pool.query(
      `SELECT u.id, u.name, u.email, u.phone,
              p.address_line, p.city, p.district,
              p.emergency_contact_name, p.emergency_contact_phone, p.notes
         FROM users u
         LEFT JOIN owner_profiles p ON p.user_id = u.id
        WHERE u.id = $1`,
      [req.user.id]
    );
    const me = rows[0];
    res.json({ ...me, profile_complete: Boolean(me.address_line) });
  } catch (err) {
    console.error(err.message);
    res.status(500).json({ error: 'Something went wrong' });
  }
});

// Save my details (first time creates them, later edits them)
router.put('/', async (req, res) => {
  const b = req.body;
  if (!isText(b.address_line)) return res.status(400).json({ error: 'Address is required' });
  if (!isText(b.city)) return res.status(400).json({ error: 'City is required' });
  if (b.name !== undefined && !isText(b.name)) {
    return res.status(400).json({ error: 'Name cannot be empty' });
  }

  const client = await pool.connect();
  try {
    await client.query('BEGIN');
    await client.query(
      `UPDATE users SET name = COALESCE($2, name), phone = COALESCE($3, phone) WHERE id = $1`,
      [req.user.id, textOrNull(b.name), textOrNull(b.phone)]
    );
    await client.query(
      `INSERT INTO owner_profiles
         (user_id, address_line, city, district,
          emergency_contact_name, emergency_contact_phone, notes)
       VALUES ($1, $2, $3, $4, $5, $6, $7)
       ON CONFLICT (user_id) DO UPDATE SET
         address_line = EXCLUDED.address_line,
         city = EXCLUDED.city,
         district = EXCLUDED.district,
         emergency_contact_name = EXCLUDED.emergency_contact_name,
         emergency_contact_phone = EXCLUDED.emergency_contact_phone,
         notes = EXCLUDED.notes,
         updated_at = NOW()`,
      [req.user.id, b.address_line.trim(), b.city.trim(), textOrNull(b.district),
       textOrNull(b.emergency_contact_name), textOrNull(b.emergency_contact_phone),
       textOrNull(b.notes)]
    );
    await client.query('COMMIT');
    res.json({ message: 'Profile saved' });
  } catch (err) {
    await client.query('ROLLBACK');
    console.error(err.message);
    res.status(500).json({ error: 'Something went wrong' });
  } finally {
    client.release();
  }
});

module.exports = router;