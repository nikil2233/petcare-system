const express = require('express');
const pool = require('../db');

const router = express.Router();

// Nearest clinics that take emergencies.
//   GET /api/emergency/nearest?lat=6.9271&lng=79.8612
// Without lat and lng, every emergency clinic is returned, sorted by name,
// so the phone numbers are always reachable even when location is refused.
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

module.exports = router;