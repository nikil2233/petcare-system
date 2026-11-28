// Free appointment slots for one vet on one day.
// Works in the vet's own time zone, and hides slots that are in the past,
// already booked (pending or confirmed), or during time off.
const SLOT_SQL = `
  SELECT s.starts_at,
         s.starts_at + make_interval(mins => v.appointment_minutes) AS ends_at
    FROM vets v
    JOIN public_vets pv ON pv.id = v.id
    JOIN vet_availability a
      ON a.vet_id = v.id AND a.weekday = EXTRACT(DOW FROM $2::date)::int
   CROSS JOIN LATERAL (
         SELECT (g AT TIME ZONE v.time_zone) AS starts_at
           FROM generate_series(
                  $2::date + a.start_time,
                  $2::date + a.end_time - make_interval(mins => v.appointment_minutes),
                  make_interval(mins => v.appointment_minutes)
                ) AS g
        ) s
   WHERE v.id = $1
     AND s.starts_at > NOW()
     AND NOT EXISTS (
           SELECT 1 FROM appointments ap
            WHERE ap.vet_id = v.id
              AND ap.status IN ('pending', 'confirmed')
              AND tstzrange(ap.starts_at, ap.ends_at)
                  && tstzrange(s.starts_at, s.starts_at + make_interval(mins => v.appointment_minutes)))
     AND NOT EXISTS (
           SELECT 1 FROM vet_time_off t
            WHERE t.vet_id = v.id
              AND tstzrange(t.starts_at, t.ends_at)
                  && tstzrange(s.starts_at, s.starts_at + make_interval(mins => v.appointment_minutes)))
   ORDER BY s.starts_at`;

// db can be the pool or a transaction client. date looks like '2026-12-01'.
async function findSlots(db, vetId, date) {
  const { rows } = await db.query(SLOT_SQL, [vetId, date]);
  return rows;
}

module.exports = { findSlots };