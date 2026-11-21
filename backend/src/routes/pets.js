const express = require('express');
const pool = require('../db');
const requireAuth = require('../middleware/requireAuth');
const requireRole = require('../middleware/requireRole');

const router = express.Router();
router.use(requireAuth, requireRole('owner'));

const TEXT_FIELDS = [
  'breed', 'color', 'microchip_number', 'medical_notes', 'allergies',
  'current_medications', 'behavior_notes', 'feeding_instructions',
];
const COLUMNS = [
  'id', 'name', 'species', 'age', 'gender', 'weight_kg', 'is_neutered',
  ...TEXT_FIELDS, 'photo_url',
].join(', ');

// Check what the owner sent and tidy it up. Returns { error } or { data }.
function clean(b) {
  const data = {};

  if (typeof b.name !== 'string' || !b.name.trim()) return { error: 'Pet name is required' };
  if (typeof b.species !== 'string' || !b.species.trim()) return { error: 'Species is required' };
  data.name = b.name.trim();
  data.species = b.species.trim();

  if (b.age == null) data.age = null;
  else if (Number.isInteger(b.age) && b.age >= 0) data.age = b.age;
  else return { error: 'Age must be a whole number, 0 or more' };

  const gender = b.gender ?? 'unknown';
  if (!['male', 'female', 'unknown'].includes(gender)) {
    return { error: 'Gender must be male, female or unknown' };
  }
  data.gender = gender;

  if (b.weight_kg == null) data.weight_kg = null;
  else if (typeof b.weight_kg === 'number' && b.weight_kg > 0 && b.weight_kg < 1000) {
    data.weight_kg = b.weight_kg;
  } else return { error: 'Weight must be a positive number in kg' };

  if (b.is_neutered == null) data.is_neutered = null;
  else if (typeof b.is_neutered === 'boolean') data.is_neutered = b.is_neutered;
  else return { error: 'is_neutered must be true or false' };

  for (const f of TEXT_FIELDS) {
    const v = b[f];
    if (v == null || v === '') data[f] = null;
    else if (typeof v === 'string') data[f] = v.trim();
    else return { error: `${f} must be text` };
  }
  return { data };
}

// Add a pet
router.post('/', async (req, res) => {
  const { error, data } = clean(req.body);
  if (error) return res.status(400).json({ error });

  // Column names come from our own list above, never from the user.
  const cols = Object.keys(data);
  const marks = cols.map((_, i) => `$${i + 2}`).join(', ');
  try {
    const { rows } = await pool.query(
      `INSERT INTO pets (owner_id, ${cols.join(', ')})
       VALUES ($1, ${marks})
       RETURNING ${COLUMNS}`,
      [req.user.id, ...Object.values(data)]
    );
    res.status(201).json(rows[0]);
  } catch (err) {
    console.error(err.message);
    res.status(500).json({ error: 'Something went wrong' });
  }
});

// List my pets
router.get('/', async (req, res) => {
  try {
    const { rows } = await pool.query(
      `SELECT ${COLUMNS} FROM pets
        WHERE owner_id = $1 AND deleted_at IS NULL
        ORDER BY created_at DESC`,
      [req.user.id]
    );
    res.json(rows);
  } catch (err) {
    console.error(err.message);
    res.status(500).json({ error: 'Something went wrong' });
  }
});

// Get one of my pets
router.get('/:id', async (req, res) => {
  const id = Number(req.params.id);
  if (!Number.isInteger(id)) return res.status(400).json({ error: 'Invalid pet id' });
  try {
    const { rows } = await pool.query(
      `SELECT ${COLUMNS} FROM pets
        WHERE id = $1 AND owner_id = $2 AND deleted_at IS NULL`,
      [id, req.user.id]
    );
    // 404 (not 403) for someone else's pet, so nobody can tell which ids exist.
    if (!rows[0]) return res.status(404).json({ error: 'Pet not found' });
    res.json(rows[0]);
  } catch (err) {
    console.error(err.message);
    res.status(500).json({ error: 'Something went wrong' });
  }
});

// Edit one of my pets (send the full pet again)
router.put('/:id', async (req, res) => {
  const id = Number(req.params.id);
  if (!Number.isInteger(id)) return res.status(400).json({ error: 'Invalid pet id' });
  const { error, data } = clean(req.body);
  if (error) return res.status(400).json({ error });

  const cols = Object.keys(data);
  const sets = cols.map((c, i) => `${c} = $${i + 3}`).join(', ');
  try {
    const { rows } = await pool.query(
      `UPDATE pets SET ${sets}
        WHERE id = $1 AND owner_id = $2 AND deleted_at IS NULL
        RETURNING ${COLUMNS}`,
      [id, req.user.id, ...Object.values(data)]
    );
    if (!rows[0]) return res.status(404).json({ error: 'Pet not found' });
    res.json(rows[0]);
  } catch (err) {
    console.error(err.message);
    res.status(500).json({ error: 'Something went wrong' });
  }
});

// Remove one of my pets (soft delete: old bookings keep their history)
router.delete('/:id', async (req, res) => {
  const id = Number(req.params.id);
  if (!Number.isInteger(id)) return res.status(400).json({ error: 'Invalid pet id' });
  try {
    const { rowCount } = await pool.query(
      `UPDATE pets SET deleted_at = NOW()
        WHERE id = $1 AND owner_id = $2 AND deleted_at IS NULL`,
      [id, req.user.id]
    );
    if (!rowCount) return res.status(404).json({ error: 'Pet not found' });
    res.status(204).end();
  } catch (err) {
    console.error(err.message);
    res.status(500).json({ error: 'Something went wrong' });
  }
});

module.exports = router;