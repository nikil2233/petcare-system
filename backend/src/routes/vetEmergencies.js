const express = require('express');
const pool = require('../db');
const requireAuth = require('../middleware/requireAuth');
const requireRole = require('../middleware/requireRole');

const router = express.Router();

// Only vets and clinic staff come in here.
// WHICH emergencies they see is decided by vet_team (their own clinic), never by role alone.
router.use(requireAuth, requireRole('vet', 'staff'));

function parseId(req, res) {
  const id = Number(req.params.id);
  if (!Number.isInteger(id)) {
    res.status(400).json({ error: 'Invalid emergency id' });
    return null;
  }
  return id;
}

// Open emergencies for my clinic. Unanswered ones come first, oldest first.
router.get('/', async (req, res) => {
  try {
    const { rows } = await pool.query(
      `SELECT e.id, e.status, e.problem, e.notes, e.distance_km, e.eta_minutes, e.alerted_at,
              ROUND(EXTRACT(EPOCH FROM (NOW() - e.alerted_at)) / 60) AS minutes_waiting,
              p.name AS pet_name, p.species, p.breed,
              u.name AS owner_name, u.phone AS owner_phone
         FROM emergency_requests e
         JOIN pets  p ON p.id = e.pet_id
         JOIN users u ON u.id = e.owner_id
        WHERE e.status IN ('alerted', 'accepted', 'arrived')
          AND e.vet_id IN (SELECT vet_id FROM vet_team WHERE user_id = $1)
        ORDER BY (e.status = 'alerted') DESC, e.alerted_at ASC`,
      [req.user.id]
    );
    res.json(rows);
  } catch (err) {
    console.error(err.message);
    res.status(500).json({ error: 'Something went wrong' });
  }
});

// Full details of one emergency: the pet, the owner and how to reach them.
// A declined or cancelled emergency is a 404, so the clinic loses access to the owner's details.
router.get('/:id', async (req, res) => {
  const id = parseId(req, res);
  if (id === null) return;

  try {
    const { rows } = await pool.query(
      `SELECT e.id, e.status, e.problem, e.notes, e.distance_km, e.eta_minutes,
              e.alerted_at, e.responded_at,
              p.id AS pet_id, p.name AS pet_name, p.species, p.breed, p.age, p.gender,
              p.color, p.weight_kg, p.is_neutered, p.microchip_number, p.medical_notes,
              p.allergies, p.current_medications, p.behavior_notes,
              u.name AS owner_name, u.phone AS owner_phone,
              op.address_line, op.city, op.district,
              op.emergency_contact_name, op.emergency_contact_phone
         FROM emergency_requests e
         JOIN pets  p ON p.id = e.pet_id
         JOIN users u ON u.id = e.owner_id
         LEFT JOIN owner_profiles op ON op.user_id = u.id
        WHERE e.id = $1
          AND e.status IN ('alerted', 'accepted', 'arrived', 'completed')
          AND e.vet_id IN (SELECT vet_id FROM vet_team WHERE user_id = $2)`,
      [id, req.user.id]
    );
    if (!rows[0]) return res.status(404).json({ error: 'Emergency not found' });
    res.json(rows[0]);
  } catch (err) {
    console.error(err.message);
    res.status(500).json({ error: 'Something went wrong' });
  }
});

// One safe way to change an emergency's status.
//  - locks the row, so two people cannot answer at the same moment
//  - only works on my own clinic's emergencies
//  - only allows the right step order
//  - tells the status history who did it, and can notify the owner
async function changeStatus(req, res, { allowedFrom, to, fields = {}, notify }) {
  const id = parseId(req, res);
  if (id === null) return;

  const client = await pool.connect();
  try {
    await client.query('BEGIN');
    await client.query(`SELECT set_config('app.current_user_id', $1, true)`, [String(req.user.id)]);

    const found = await client.query(
      `SELECT e.id, e.status, e.owner_id, p.name AS pet_name, v.clinic_name
         FROM emergency_requests e
         JOIN pets p ON p.id = e.pet_id
         JOIN vets v ON v.id = e.vet_id
        WHERE e.id = $1
          AND e.vet_id IN (SELECT vet_id FROM vet_team WHERE user_id = $2)
        FOR UPDATE OF e`,
      [id, req.user.id]
    );
    const current = found.rows[0];
    if (!current) {
      await client.query('ROLLBACK');
      return res.status(404).json({ error: 'Emergency not found' });
    }
    if (!allowedFrom.includes(current.status)) {
      await client.query('ROLLBACK');
      return res.status(409).json({ error: `This emergency is already ${current.status}` });
    }

    // Column names below come from our own code, never from the user.
    const sets = [
      'status = $2',
      'handled_by = COALESCE(handled_by, $3)',   // remembers who ANSWERED first
      'responded_at = COALESCE(responded_at, NOW())',
    ];
    const params = [id, to, req.user.id];
    for (const [column, value] of Object.entries(fields)) {
      params.push(value);
      sets.push(`${column} = $${params.length}`);
    }
    const updated = await client.query(
      `UPDATE emergency_requests SET ${sets.join(', ')}
        WHERE id = $1
        RETURNING id, status, eta_minutes, decline_reason, responded_at`,
      params
    );

    if (notify) {
      const message = notify(current);
      await client.query(
        `INSERT INTO notifications (user_id, type, title, body, link)
         VALUES ($1, $2, $3, $4, $5)`,
        [current.owner_id, message.type, message.title, message.body, `/emergencies/${id}`]
      );
    }

    await client.query('COMMIT');
    res.json(updated.rows[0]);
  } catch (err) {
    await client.query('ROLLBACK');
    console.error(err.message);
    res.status(500).json({ error: 'Something went wrong' });
  } finally {
    client.release();
  }
}

// Accept, with how many minutes until the team is ready for the pet.
router.post('/:id/accept', (req, res) => {
  const { eta_minutes: eta } = req.body ?? {};
  if (!Number.isInteger(eta) || eta < 0 || eta > 600) {
    return res.status(400).json({ error: 'eta_minutes must be a whole number from 0 to 600' });
  }
  return changeStatus(req, res, {
    allowedFrom: ['alerted'],
    to: 'accepted',
    fields: { eta_minutes: eta },
    notify: (e) => ({
      type: 'emergency_accepted',
      title: `${e.clinic_name} accepted your emergency`,
      body: eta === 0
        ? `${e.pet_name}: the team is ready now. Please come as soon as you safely can.`
        : `${e.pet_name}: the team will be ready in about ${eta} minutes. Please come as soon as you safely can.`,
    }),
  });
});

// Decline, with a reason, so the owner can quickly choose another clinic.
router.post('/:id/decline', (req, res) => {
  const { reason: raw } = req.body ?? {};
  if (raw != null && (typeof raw !== 'string' || raw.length > 255)) {
    return res.status(400).json({ error: 'reason must be text, 255 characters or less' });
  }
  const reason = raw && raw.trim() ? raw.trim() : 'The clinic cannot take this case right now';
  return changeStatus(req, res, {
    allowedFrom: ['alerted'],
    to: 'declined',
    fields: { decline_reason: reason },
    notify: (e) => ({
      type: 'emergency_declined',
      title: `${e.clinic_name} cannot take your emergency`,
      body: `${reason}. Please choose another clinic or call one now.`,
    }),
  });
});

// The pet has arrived at the clinic.
router.post('/:id/arrived', (req, res) =>
  changeStatus(req, res, { allowedFrom: ['accepted'], to: 'arrived' })
);

// Treatment is finished.
router.post('/:id/complete', (req, res) =>
  changeStatus(req, res, { allowedFrom: ['arrived'], to: 'completed' })
);

module.exports = router;