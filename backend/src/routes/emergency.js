const express = require('express');
const pool = require('../db');
const requireAuth = require('../middleware/requireAuth');
const requireRole = require('../middleware/requireRole');

const router = express.Router();

const PROBLEMS = [
  'accident', 'bleeding', 'breathing', 'poisoning',
  'seizure', 'vomiting', 'not_sure', 'other',
];

// ---------------------------------------------------------------
// Part A: nearest clinics that take emergencies (no login needed,
// because in an emergency people must always reach a phone number).
//   GET /api/emergency/nearest?lat=6.9271&lng=79.8612
// ---------------------------------------------------------------
router.get('/nearest', async (req, res) => {
  const hasLocation = req.query.lat !== undefined || req.query.lng !== undefined;
  let lat = null;
  let lng = null;

  if (hasLocation) {
    lat = Number(req.query.lat);
    lng = Number(req.query.lng);
    const okLat = Number.isFinite(lat) && lat >= -90 && lat <= 90;
    const okLng = Number.isFinite(lng) && lng >= -180 && lng <= 180;
    if (!okLat || !okLng) {
      return res.status(400).json({ error: 'lat and lng must be real coordinates' });
    }
  }

  try {
    // Straight-line distance in km (haversine). Real driving distance comes later.
    const { rows } = await pool.query(
      `SELECT pv.id, pv.clinic_name, pv.address, pv.lat, pv.lng, pv.opening_hours,
              COALESCE(v.emergency_phone, pv.phone) AS call_phone,
              CASE WHEN $1::float8 IS NULL THEN NULL ELSE
                ROUND((6371 * 2 * ASIN(SQRT(
                  POWER(SIN(RADIANS(pv.lat - $1::float8) / 2), 2) +
                  COS(RADIANS($1::float8)) * COS(RADIANS(pv.lat)) *
                  POWER(SIN(RADIANS(pv.lng - $2::float8) / 2), 2)
                )))::numeric, 1)
              END AS distance_km
         FROM public_vets pv
         JOIN vets v ON v.id = pv.id
        WHERE v.accepts_emergencies
        ORDER BY distance_km ASC NULLS LAST, pv.clinic_name
        LIMIT 5`,
      [lat, lng]
    );
    res.json(rows);
  } catch (err) {
    console.error(err.message);
    res.status(500).json({ error: 'Something went wrong' });
  }
});

// ---------------------------------------------------------------
// Part B: the one-click emergency request (pet owners only).
//   POST /api/emergency/requests
//   { "pet_id": 1, "vet_id": 1, "lat": 6.93, "lng": 79.86,
//     "problem": "accident", "notes": "optional" }
// Only pet_id and vet_id are required.
// ---------------------------------------------------------------
router.post('/requests', requireAuth, requireRole('owner'), async (req, res) => {
  const { pet_id, vet_id, lat, lng, notes } = req.body;
  const problem = req.body.problem ?? 'not_sure';

  if (!Number.isInteger(pet_id) || !Number.isInteger(vet_id)) {
    return res.status(400).json({ error: 'pet_id and vet_id are required' });
  }
  if (!PROBLEMS.includes(problem)) {
    return res.status(400).json({ error: 'Unknown problem type' });
  }
  if (notes != null && (typeof notes !== 'string' || notes.length > 500)) {
    return res.status(400).json({ error: 'Notes must be text, 500 characters or less' });
  }

  // Location is optional: a refused location must never block an emergency.
  let ownerLat = null;
  let ownerLng = null;
  if (lat != null || lng != null) {
    const okLat = typeof lat === 'number' && lat >= -90 && lat <= 90;
    const okLng = typeof lng === 'number' && lng >= -180 && lng <= 180;
    if (!okLat || !okLng) {
      return res.status(400).json({ error: 'lat and lng must be real coordinates' });
    }
    ownerLat = lat;
    ownerLng = lng;
  }

  const client = await pool.connect();
  try {
    await client.query('BEGIN');
    // Tells the history log who made this change.
    await client.query(`SELECT set_config('app.current_user_id', $1, true)`, [String(req.user.id)]);

    // The pet must be mine.
    const petResult = await client.query(
      `SELECT id, name, species FROM pets
        WHERE id = $1 AND owner_id = $2 AND deleted_at IS NULL`,
      [pet_id, req.user.id]
    );
    const pet = petResult.rows[0];
    if (!pet) {
      await client.query('ROLLBACK');
      return res.status(404).json({ error: 'Pet not found' });
    }

    // The clinic must be approved and take emergencies.
    const clinicResult = await client.query(
      `SELECT pv.id, pv.clinic_name,
              COALESCE(v.emergency_phone, pv.phone) AS call_phone,
              CASE WHEN $2::float8 IS NULL THEN NULL ELSE
                ROUND((6371 * 2 * ASIN(SQRT(
                  POWER(SIN(RADIANS(pv.lat - $2::float8) / 2), 2) +
                  COS(RADIANS($2::float8)) * COS(RADIANS(pv.lat)) *
                  POWER(SIN(RADIANS(pv.lng - $3::float8) / 2), 2)
                )))::numeric, 2)
              END AS distance_km
         FROM public_vets pv
         JOIN vets v ON v.id = pv.id
        WHERE pv.id = $1 AND v.accepts_emergencies`,
      [vet_id, ownerLat, ownerLng]
    );
    const clinic = clinicResult.rows[0];
    if (!clinic) {
      await client.query('ROLLBACK');
      return res.status(404).json({ error: 'That clinic is not available for emergencies' });
    }

    // Create the request. Details come from the profile later, so nothing is copied here.
    const inserted = await client.query(
      `INSERT INTO emergency_requests
         (owner_id, pet_id, vet_id, owner_lat, owner_lng, distance_km, problem, notes)
       VALUES ($1, $2, $3, $4, $5, $6, $7, $8)
       RETURNING id, status, problem, notes, distance_km, alerted_at`,
      [req.user.id, pet.id, clinic.id, ownerLat, ownerLng, clinic.distance_km,
       problem, notes ? notes.trim() : null]
    );
    const request = inserted.rows[0];

    // Alert everyone on the clinic team: the vet and the nurses or staff.
    const ownerResult = await client.query(
      `SELECT name, phone FROM users WHERE id = $1`,
      [req.user.id]
    );
    const owner = ownerResult.rows[0];
    const title = `EMERGENCY: ${pet.name} (${pet.species})`;
    const body =
      `Problem: ${problem}. Owner: ${owner.name}` +
      (owner.phone ? `, ${owner.phone}` : '') + '.' +
      (clinic.distance_km ? ` About ${clinic.distance_km} km away.` : '');
    await client.query(
      `INSERT INTO notifications (user_id, type, title, body, link)
       SELECT user_id, 'emergency_alert', $2, $3, $4
         FROM vet_team WHERE vet_id = $1`,
      [clinic.id, title, body, `/vet/emergencies/${request.id}`]
    );

    await client.query('COMMIT');
    res.status(201).json({
      request,
      clinic: { id: clinic.id, clinic_name: clinic.clinic_name, call_phone: clinic.call_phone },
      message: 'The clinic has been alerted. You can also call them now.',
    });
  } catch (err) {
    await client.query('ROLLBACK');
    if (err.code === '23505') {
      return res.status(409).json({ error: 'This pet already has an open emergency request' });
    }
    console.error(err.message);
    res.status(500).json({ error: 'Something went wrong' });
  } finally {
    client.release();
  }
});

// My emergency requests and their status.
router.get('/requests/mine', requireAuth, requireRole('owner'), async (req, res) => {
  try {
    const { rows } = await pool.query(
      `SELECT e.id, e.status, e.problem, e.eta_minutes, e.decline_reason,
              e.distance_km, e.alerted_at, e.responded_at,
              p.name AS pet_name, v.clinic_name,
              COALESCE(v.emergency_phone, v.phone) AS call_phone
         FROM emergency_requests e
         JOIN pets p ON p.id = e.pet_id
         JOIN vets v ON v.id = e.vet_id
        WHERE e.owner_id = $1
        ORDER BY e.created_at DESC
        LIMIT 20`,
      [req.user.id]
    );
    res.json(rows);
  } catch (err) {
    console.error(err.message);
    res.status(500).json({ error: 'Something went wrong' });
  }
});

module.exports = router;
