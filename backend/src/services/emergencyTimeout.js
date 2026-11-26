// An emergency nobody answers within a few minutes becomes 'no_response',
// and the owner is told to call the clinic or choose another one.
const MINUTES = Number(process.env.EMERGENCY_RESPONSE_MINUTES) || 5;

async function expireUnanswered(db) {
  // One statement does both jobs, so they cannot get out of step.
  // If a nurse accepts at the same moment, the status is no longer 'alerted' and nothing changes.
  const { rowCount } = await db.query(
    `WITH expired AS (
       UPDATE emergency_requests
          SET status = 'no_response'
        WHERE status = 'alerted'
          AND alerted_at < NOW() - make_interval(mins => $1::int)
        RETURNING id, owner_id, pet_id, vet_id
     )
     INSERT INTO notifications (user_id, type, title, body, link)
     SELECT x.owner_id, 'emergency_no_response',
            v.clinic_name || ' has not responded',
            p.name || ': no answer yet. Please call ' ||
              COALESCE(v.emergency_phone, v.phone, 'the clinic') ||
              ' now, or choose another clinic.',
            '/emergencies/' || x.id
       FROM expired x
       JOIN pets p ON p.id = x.pet_id
       JOIN vets v ON v.id = x.vet_id`,
    [MINUTES]
  );
  return rowCount;
}

module.exports = { expireUnanswered };