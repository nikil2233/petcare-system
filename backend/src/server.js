require('dotenv').config();
const express = require('express');
const cors = require('cors');
const helmet = require('helmet');
const pool = require('./db');
const { expireUnanswered } = require('./services/emergencyTimeout');

const app = express();
app.use(helmet());
app.use(cors());
app.use(express.json());

// Express 5 leaves req.body undefined when no JSON body is sent.
// An empty object lets the routes reply 400 ("... is required") instead of crashing with 500.
app.use((req, res, next) => {
  req.body ??= {};
  next();
});

// Before any emergency request is handled, close the ones nobody answered in time.
app.use(['/api/emergency', '/api/vet/emergencies'], async (req, res, next) => {
  try {
    await expireUnanswered(pool);
  } catch (err) {
    console.error(err.message);
  }
  next();
});

app.use('/api/auth', require('./routes/auth'));
app.use('/api/profile', require('./routes/profile'));
app.use('/api/pets', require('./routes/pets'));
app.use('/api/clients', require('./routes/clients'));
app.use('/api/vets', require('./routes/vets'));
app.use('/api/emergency', require('./routes/emergency'));
app.use('/api/emergency/requests', require('./routes/ownerEmergencies'));
app.use('/api/vet/emergencies', require('./routes/vetEmergencies'));
app.use('/api/notifications', require('./routes/notifications'));

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

const port = process.env.PORT || 4000;
app.listen(port, () => console.log(`API running on http://localhost:${port}`));

// Every 30 seconds, close emergencies that nobody answered.
setInterval(() => {
  expireUnanswered(pool).catch((err) => console.error(err.message));
}, 30 * 1000);