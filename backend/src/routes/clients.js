const express = require('express');
const pool = require('../db');
const requireAuth = require('../middleware/requireAuth');
const requireRole = require('../middleware/requireRole');

const router = express.Router();

// Only vets, shelters and their staff come in here.
// WHICH pets they may see is decided by the pet_access view (bookings), not by role alone.
router.use(requireAuth, requireRole('vet', 'shelter', 'staff'));

// The pets I may see, because their owner booked with my clinic or shelter
router.get('/', async (req, res) => {
  try {
    const { rows } = await pool.query(
      `SELECT DISTINCT pa.pet_id, p.name AS pet_name, p.species, p.breed,
              pa.owner_id, u.name AS owner_name, pa.via
         FROM pet_access pa
         JOIN pets  p ON p.id = pa.pet_id AND p.deleted_at IS NULL
         JOIN users u ON u.id = pa.owner_id
        WHERE pa.viewer_user_id = $1
        ORDER BY p.name`,
      [req.user.id]
    );
    res.json(rows);
  } catch (err) {
    console.error(err.message);
    res.status(500).json({ error: 'Something went wrong' });
  }
});

// Full details of one pet and its owner, only if there is a booking with me
router.get('/pets/:id', async (req, res) => {
  const id = Number(req.params.id);
  if (!Number.isInteger(id)) return res.status(400).json({ error: 'Invalid pet id' });

  try {
    const { rows } = await pool.query(
      `SELECT p.id, p.name, p.species, p.breed, p.age, p.gender, p.color, p.weight_kg,
              p.is_neutered, p.microchip_number, p.medical_notes, p.allergies,
              p.current_medications, p.behavior_notes, p.feeding_instructions,
              u.id AS owner_id, u.name AS owner_name, u.phone AS owner_phone,
              op.address_line, op.city, op.district,
              op.emergency_contact_name, op.emergency_contact_phone,
              pa.via
         FROM pet_access pa
         JOIN pets  p ON p.id = pa.pet_id AND p.deleted_at IS NULL
         JOIN users u ON u.id = pa.owner_id
         LEFT JOIN owner_profiles op ON op.user_id = u.id
        WHERE pa.viewer_user_id = $1 AND pa.pet_id = $2
        LIMIT 1`,
      [req.user.id, id]
    );
    // No booking with me = 404, the same answer as "no such pet".
    if (!rows[0]) return res.status(404).json({ error: 'Pet not found' });

    const r = rows[0];
    res.json({
      via: r.via,
      pet: {
        id: r.id, name: r.name, species: r.species, breed: r.breed, age: r.age,
        gender: r.gender, color: r.color, weight_kg: r.weight_kg,
        is_neutered: r.is_neutered, microchip_number: r.microchip_number,
        medical_notes: r.medical_notes, allergies: r.allergies,
        current_medications: r.current_medications,
        behavior_notes: r.behavior_notes, feeding_instructions: r.feeding_instructions,
      },
      owner: {
        id: r.owner_id, name: r.owner_name, phone: r.owner_phone,
        address_line: r.address_line, city: r.city, district: r.district,
        emergency_contact_name: r.emergency_contact_name,
        emergency_contact_phone: r.emergency_contact_phone,
      },
    });
  } catch (err) {
    console.error(err.message);
    res.status(500).json({ error: 'Something went wrong' });
  }
});

module.exports = router;