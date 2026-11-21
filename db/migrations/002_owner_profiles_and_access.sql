-- Migration 002: owner profile, richer pet details, and who may see what.
-- Run after 001_init.sql.

-- 1. The owner's own details (kept apart from the login table on purpose).
--    If a row exists for a user, their profile is complete.
CREATE TABLE owner_profiles (
    user_id                 INT PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
    address_line            VARCHAR(255) NOT NULL,
    city                    VARCHAR(100) NOT NULL,
    district                VARCHAR(100),
    emergency_contact_name  VARCHAR(100),
    emergency_contact_phone VARCHAR(30),
    notes                   TEXT,
    updated_at              TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- 2. More details about each pet.
ALTER TABLE pets
    ADD COLUMN gender               VARCHAR(10) NOT NULL DEFAULT 'unknown'
                                    CHECK (gender IN ('male', 'female', 'unknown')),
    ADD COLUMN color                VARCHAR(50),
    ADD COLUMN weight_kg            NUMERIC(5, 2) CHECK (weight_kg > 0),
    ADD COLUMN is_neutered          BOOLEAN,
    ADD COLUMN microchip_number     VARCHAR(30),
    ADD COLUMN allergies            TEXT,
    ADD COLUMN current_medications  TEXT,
    ADD COLUMN behavior_notes       TEXT,
    ADD COLUMN feeding_instructions TEXT;

-- 3. Who may see which owner and pet. One row per (viewer, owner, pet).
--    Vets (and clinic staff) see patients through appointments.
--    Shelters (and shelter staff) see guests through boarding requests.
--    The API checks this view before it shows any owner or pet details.
CREATE VIEW pet_access AS
    SELECT vt.user_id AS viewer_user_id, a.owner_id, a.pet_id, 'vet'::text AS via
      FROM appointments a
      JOIN vet_team vt ON vt.vet_id = a.vet_id
     WHERE a.status IN ('pending', 'confirmed', 'completed')
    UNION
    SELECT st.user_id, b.owner_id, b.pet_id, 'shelter'::text
      FROM boarding_requests b
      JOIN shelter_team st ON st.shelter_id = b.shelter_id
     WHERE b.status IN ('pending', 'accepted');