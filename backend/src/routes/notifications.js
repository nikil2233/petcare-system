const express = require('express');
const pool = require('../db');
const requireAuth = require('../middleware/requireAuth');

const router = express.Router();
router.use(requireAuth);

// My notifications, newest first.  Add ?unread=true to see only the unread ones.
router.get('/', async (req, res) => {
  const onlyUnread = req.query.unread === 'true';
  try {
    const { rows } = await pool.query(
      `SELECT id, type, title, body, link, is_read, created_at
         FROM notifications
        WHERE user_id = $1 AND ($2::boolean = FALSE OR is_read = FALSE)
        ORDER BY created_at DESC, id DESC
        LIMIT 50`,
      [req.user.id, onlyUnread]
    );
    res.json(rows);
  } catch (err) {
    console.error(err.message);
    res.status(500).json({ error: 'Something went wrong' });
  }
});

// How many unread I have (for the badge on a bell icon).
router.get('/unread-count', async (req, res) => {
  try {
    const { rows } = await pool.query(
      `SELECT COUNT(*)::int AS unread
         FROM notifications
        WHERE user_id = $1 AND is_read = FALSE`,
      [req.user.id]
    );
    res.json(rows[0]);
  } catch (err) {
    console.error(err.message);
    res.status(500).json({ error: 'Something went wrong' });
  }
});

// Mark all of my notifications as read.
router.post('/read-all', async (req, res) => {
  try {
    const { rowCount } = await pool.query(
      `UPDATE notifications SET is_read = TRUE
        WHERE user_id = $1 AND is_read = FALSE`,
      [req.user.id]
    );
    res.json({ marked: rowCount });
  } catch (err) {
    console.error(err.message);
    res.status(500).json({ error: 'Something went wrong' });
  }
});

// Mark one notification as read. Someone else's notification is a 404.
router.post('/:id/read', async (req, res) => {
  const id = Number(req.params.id);
  if (!Number.isInteger(id)) return res.status(400).json({ error: 'Invalid notification id' });

  try {
    const { rows } = await pool.query(
      `UPDATE notifications SET is_read = TRUE
        WHERE id = $1 AND user_id = $2
        RETURNING id, is_read`,
      [id, req.user.id]
    );
    if (!rows[0]) return res.status(404).json({ error: 'Notification not found' });
    res.json(rows[0]);
  } catch (err) {
    console.error(err.message);
    res.status(500).json({ error: 'Something went wrong' });
  }
});

module.exports = router;