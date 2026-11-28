const express = require('express');
const pool = require('../db');
const { findSlots } = require('../services/slots');

const router = express.Router();

// Public list of approved vets (reads from the public_vets view).
router.get('/', async (req, res) => {
  try {
    const { rows } = await pool.query(
      `SELECT id, clinic_name, address, lat, lng, phone, opening_hours
         FROM public_vets
        ORDER BY clinic_name`
    );
    res.json(rows);
  } catch (err) {
    console.error(err.message);
    res.status(500).json({ error: 'Something went wrong' });
  }
});

// Free slots for one vet on one day:  GET /api/vets/1/slots?date=2026-12-01
router.get('/:id/slots', async (req, res) => {
  const id = Number(req.params.id);
  const date = req.query.date;
  if (!Number.isInteger(id)) return res.status(400).json({ error: 'Invalid vet id' });
  if (typeof date !== 'string' || !/^\d{4}-\d{2}-\d{2}$/.test(date)) {
    return res.status(400).json({ error: 'date must look like 2026-12-01' });
  }

  try {
    res.json(await findSlots(pool, id, date));
  } catch (err) {
    // Postgres error codes starting with 22 mean "bad value", for example 2026-13-45.
    if (String(err.code).startsWith('22')) {
      return res.status(400).json({ error: 'That is not a real date' });
    }
    console.error(err.message);
    res.status(500).json({ error: 'Something went wrong' });
  }
});

module.exports = router;