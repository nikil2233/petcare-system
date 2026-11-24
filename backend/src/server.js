require('dotenv').config();
const express = require('express');
const cors = require('cors');
const helmet = require('helmet');
const pool = require('./db');

const app = express();
app.use(helmet());
app.use(cors());
app.use(express.json());
app.use('/api/auth', require('./routes/auth'));
app.use('/api/profile', require('./routes/profile'));
app.use('/api/pets', require('./routes/pets'));
app.use('/api/clients', require('./routes/clients'));
app.use('/api/emergency', require('./routes/emergency'));
app.use('/api/vet/emergencies', require('./routes/vetEmergencies'));

// Health check: is the server up, and can it reach the database?
app.get('/health', async (req, res) => {
  try {
    await pool.query('SELECT 1');
    res.json({ status: 'ok', database: 'connected' });
  } catch (err) {
    console.error(err.message);
    res.status(500).json({ status: 'error', database: 'unreachable' });
  }
});

// Public list of approved vets (reads from the public_vets view).
app.get('/api/vets', async (req, res) => {
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

const port = process.env.PORT || 4000;
app.listen(port, () => console.log(`API running on http://localhost:${port}`));