const express = require('express');
const pool = require('../db');
const requireAuth = require('../middleware/requireAuth');
const requireRole = require('../middleware/requireRole');

const router = express.Router();

// The owner cancels their own emergency (only while it is alerted or accepted).
//   POST /api/emergency/requests/:id/cancel
router.post('/:id/cancel', requireAuth, requireRole('owner'), async (req, res) => {
  const id = Number(req.params.id);
  if (!Number.isInteger(id)) return res.status(400).json({ error: 'Invalid emergency id' });

  const client = await pool.connect();
  try {
    await client.query('BEGIN');
    await client.query(`SELECT set_config('app.current_user_id', $1, true)`, [String(req.user.id)]);

    // Lock the row so a nurse and the owner cannot change it at the same moment.
    const found = await client.query(
      `SELECT e.id, e.status, e.vet_id, p.name AS pet_name
         FROM emergency_requests e
         JOIN pets p ON p.id = e.pet_id
        WHERE e.id = $1 AND e.owner_id = $2
        FOR UPDATE OF e`,
      [id, req.user.id]
    );
    const current = found.rows[0];
    if (!current) {
      await client.query('ROLLBACK');
      return res.status(404).json({ error: 'Emergency not found' });
    }
    if (!['alerted', 'accepted'].includes(current.status)) {
      await client.query('ROLLBACK');
      const hint = current.status === 'arrived' ? ' Please speak to the clinic.' : '';
      return res.status(409).json({ error: `This emergency is already ${current.status}.${hint}` });
    }

    const updated = await client.query(
      `UPDATE emergency_requests SET status = 'cancelled'
        WHERE id = $1
        RETURNING id, status`,
      [id]
    );

    // Tell the whole clinic team, so they stop preparing.
    await client.query(
      `INSERT INTO notifications (user_id, type, title, body, link)
       SELECT user_id, 'emergency_cancelled',
              'Emergency cancelled: ' || $2::text,
              'The owner cancelled this emergency. No need to prepare.',
              '/vet/emergencies/' || $3::text
         FROM vet_team WHERE vet_id = $1`,
      [current.vet_id, current.pet_name, id]
    );

    await client.query('COMMIT');
    res.json(updated.rows[0]);
  } catch (err) {
    await client.query('ROLLBACK');
    console.error(err.message);
    res.status(500).json({ error: 'Something went wrong' });
  } finally {
    client.release();
  }
});

module.exports = router;