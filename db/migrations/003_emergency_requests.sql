-- Migration 003: emergency requests, and categories for normal appointments.
-- Run after 002_owner_profiles_and_access.sql.

-- 1. Which clinics take emergencies, and which number to call.
ALTER TABLE vets
    ADD COLUMN accepts_emergencies BOOLEAN NOT NULL DEFAULT FALSE,
    ADD COLUMN emergency_phone     VARCHAR(30);

-- 2. A category for normal bookings (vaccination, small wound, mild illness...).
ALTER TABLE appointments
    ADD COLUMN category VARCHAR(20) NOT NULL DEFAULT 'other'
        CHECK (category IN ('vaccination', 'checkup', 'minor_injury', 'illness', 'other'));

-- 3. Emergency requests. No time slot: the owner is "coming now".
CREATE TABLE emergency_requests (
    id             SERIAL PRIMARY KEY,
    owner_id       INT NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
    pet_id         INT NOT NULL,
    vet_id         INT NOT NULL REFERENCES vets(id)  ON DELETE RESTRICT,
    owner_lat      DOUBLE PRECISION CHECK (owner_lat BETWEEN -90 AND 90),    -- where the owner was
    owner_lng      DOUBLE PRECISION CHECK (owner_lng BETWEEN -180 AND 180),
    distance_km    NUMERIC(6, 2),
    eta_minutes    INT CHECK (eta_minutes BETWEEN 0 AND 600),                -- the vet's reply
    problem        VARCHAR(20) NOT NULL DEFAULT 'not_sure'
                   CHECK (problem IN ('accident', 'bleeding', 'breathing', 'poisoning',
                                      'seizure', 'vomiting', 'not_sure', 'other')),
    notes          VARCHAR(500),
    status         VARCHAR(20) NOT NULL DEFAULT 'alerted'
                   CHECK (status IN ('alerted', 'accepted', 'declined', 'arrived',
                                     'completed', 'cancelled', 'no_response')),
    decline_reason VARCHAR(255),
    handled_by     INT REFERENCES users(id) ON DELETE SET NULL,   -- the vet or nurse who answered
    alerted_at     TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    responded_at   TIMESTAMPTZ,
    created_at     TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    FOREIGN KEY (pet_id, owner_id) REFERENCES pets(id, owner_id) ON DELETE RESTRICT
);

-- A pet can have only ONE open emergency at a time (stops spam and prank alerts).
CREATE UNIQUE INDEX uq_one_open_emergency_per_pet
    ON emergency_requests(pet_id)
    WHERE status IN ('alerted', 'accepted', 'arrived');
CREATE INDEX idx_emergency_vet_open ON emergency_requests(vet_id, status, alerted_at DESC);
CREATE INDEX idx_emergency_owner    ON emergency_requests(owner_id, created_at DESC);

-- 4. Let the history log and notifications know about emergencies.
ALTER TABLE status_history DROP CONSTRAINT status_history_entity_type_check;
ALTER TABLE status_history ADD CONSTRAINT status_history_entity_type_check
    CHECK (entity_type IN ('appointment', 'boarding_request', 'order', 'prescription', 'emergency'));

ALTER TABLE notifications DROP CONSTRAINT notifications_type_check;
ALTER TABLE notifications ADD CONSTRAINT notifications_type_check
    CHECK (type IN (
        'appointment_requested', 'appointment_confirmed',
        'appointment_declined',  'appointment_cancelled', 'appointment_reminder',
        'boarding_requested', 'boarding_accepted', 'boarding_declined',
        'order_placed', 'order_status_changed',
        'prescription_requested', 'prescription_reviewed',
        'approval_requested', 'account_approved', 'account_rejected',
        'emergency_alert', 'emergency_accepted', 'emergency_declined', 'emergency_no_response',
        'new_message'
    ));

CREATE TRIGGER trg_log_emergency
    AFTER INSERT OR UPDATE OF status ON emergency_requests
    FOR EACH ROW EXECUTE FUNCTION log_status_change('emergency');

-- 5. The clinic's team (vet + nurses/staff) can see the pet and owner details
--    from the moment an emergency is alerted, until it is declined or cancelled.
CREATE OR REPLACE VIEW pet_access AS
    SELECT vt.user_id AS viewer_user_id, a.owner_id, a.pet_id, 'vet'::text AS via
      FROM appointments a
      JOIN vet_team vt ON vt.vet_id = a.vet_id
     WHERE a.status IN ('pending', 'confirmed', 'completed')
    UNION
    SELECT st.user_id, b.owner_id, b.pet_id, 'shelter'::text
      FROM boarding_requests b
      JOIN shelter_team st ON st.shelter_id = b.shelter_id
     WHERE b.status IN ('pending', 'accepted')
    UNION
    SELECT vt.user_id, e.owner_id, e.pet_id, 'vet'::text
      FROM emergency_requests e
      JOIN vet_team vt ON vt.vet_id = e.vet_id
     WHERE e.status IN ('alerted', 'accepted', 'arrived', 'completed');