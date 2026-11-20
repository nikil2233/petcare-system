-- Pet care platform: initial migration (v3)
-- Safe to run on an empty database. No DROP statements, no seed users.
-- Needs PostgreSQL 13+ (btree_gist is a trusted extension, the DB owner can create it).
--
-- Conventions
--   * All timestamps are TIMESTAMPTZ (stored in UTC, shown in Asia/Colombo by the app).
--   * Nothing that has history is hard-deleted: users, pets and products are soft-deleted.
--   * Money is NUMERIC(10,2), in LKR.

CREATE EXTENSION IF NOT EXISTS btree_gist;

-- =====================================================================
-- 1. Accounts and authentication
-- =====================================================================
-- 'Guest' is not a role. It means "not logged in", so it is never stored.
-- Public signup may only create owner / vet / shelter / seller (enforced in the API).
-- Admins are created by a script. Staff are created by their vet or shelter owner.
CREATE TABLE users (
    id                SERIAL PRIMARY KEY,
    name              VARCHAR(100) NOT NULL,
    email             VARCHAR(255) NOT NULL,
    password_hash     VARCHAR(255) NOT NULL,
    role              VARCHAR(20)  NOT NULL DEFAULT 'owner'
                      CHECK (role IN ('owner', 'vet', 'shelter', 'seller', 'staff', 'admin')),
    phone             VARCHAR(30),
    email_verified_at TIMESTAMPTZ,
    is_active         BOOLEAN NOT NULL DEFAULT TRUE,   -- admin can suspend
    deleted_at        TIMESTAMPTZ,                     -- soft delete
    created_at        TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
-- Case-insensitive uniqueness: A@x.com and a@x.com are the same account.
CREATE UNIQUE INDEX uq_users_email_lower ON users (lower(email));

-- One-time tokens for email verification and password reset.
-- Store only a SHA-256 hash of the token, never the token itself.
CREATE TABLE auth_tokens (
    id          SERIAL PRIMARY KEY,
    user_id     INT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    purpose     VARCHAR(30) NOT NULL CHECK (purpose IN ('verify_email', 'reset_password')),
    token_hash  CHAR(64) NOT NULL UNIQUE,
    expires_at  TIMESTAMPTZ NOT NULL,
    used_at     TIMESTAMPTZ,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE pets (
    id            SERIAL PRIMARY KEY,
    owner_id      INT NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
    name          VARCHAR(100) NOT NULL,
    species       VARCHAR(50)  NOT NULL,
    breed         VARCHAR(100),
    age           INT CHECK (age >= 0),
    medical_notes TEXT,
    photo_url     VARCHAR(255),
    deleted_at    TIMESTAMPTZ,                         -- owner "removes" a pet, history stays
    created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE (id, owner_id)                              -- lets other tables prove "this pet belongs to this owner"
);

-- =====================================================================
-- 2. Business profiles (one per vet / shelter / seller account)
-- =====================================================================
-- approval_status: new businesses stay hidden from the public until an admin approves them.
CREATE TABLE vets (
    id                  SERIAL PRIMARY KEY,
    user_id             INT NOT NULL UNIQUE REFERENCES users(id) ON DELETE RESTRICT,
    clinic_name         VARCHAR(150) NOT NULL,
    address             VARCHAR(255) NOT NULL,
    lat                 DOUBLE PRECISION NOT NULL CHECK (lat BETWEEN -90 AND 90),    -- set from a map pin in the UI
    lng                 DOUBLE PRECISION NOT NULL CHECK (lng BETWEEN -180 AND 180),
    phone               VARCHAR(30),
    opening_hours       VARCHAR(100),
    image_url           VARCHAR(255),
    time_zone           VARCHAR(50) NOT NULL DEFAULT 'Asia/Colombo',
    appointment_minutes INT NOT NULL DEFAULT 30 CHECK (appointment_minutes BETWEEN 10 AND 240),
    approval_status     VARCHAR(20) NOT NULL DEFAULT 'pending'
                        CHECK (approval_status IN ('pending', 'approved', 'rejected')),
    rejection_reason    VARCHAR(255),
    reviewed_by         INT REFERENCES users(id) ON DELETE SET NULL,
    reviewed_at         TIMESTAMPTZ,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE shelters (
    id               SERIAL PRIMARY KEY,
    user_id          INT NOT NULL UNIQUE REFERENCES users(id) ON DELETE RESTRICT,
    name             VARCHAR(150) NOT NULL,
    address          VARCHAR(255) NOT NULL,
    lat              DOUBLE PRECISION NOT NULL CHECK (lat BETWEEN -90 AND 90),
    lng              DOUBLE PRECISION NOT NULL CHECK (lng BETWEEN -180 AND 180),
    phone            VARCHAR(30),
    image_url        VARCHAR(255),
    capacity         INT NOT NULL CHECK (capacity > 0),
    price_per_day    NUMERIC(10, 2) NOT NULL CHECK (price_per_day >= 0),
    approval_status  VARCHAR(20) NOT NULL DEFAULT 'pending'
                     CHECK (approval_status IN ('pending', 'approved', 'rejected')),
    rejection_reason VARCHAR(255),
    reviewed_by      INT REFERENCES users(id) ON DELETE SET NULL,
    reviewed_at      TIMESTAMPTZ,
    created_at       TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE sellers (
    id               SERIAL PRIMARY KEY,
    user_id          INT NOT NULL UNIQUE REFERENCES users(id) ON DELETE RESTRICT,
    store_name       VARCHAR(150) NOT NULL,
    address          VARCHAR(255),
    phone            VARCHAR(30),
    delivery_fee     NUMERIC(10, 2) NOT NULL DEFAULT 0 CHECK (delivery_fee >= 0),
    approval_status  VARCHAR(20) NOT NULL DEFAULT 'pending'
                     CHECK (approval_status IN ('pending', 'approved', 'rejected')),
    rejection_reason VARCHAR(255),
    reviewed_by      INT REFERENCES users(id) ON DELETE SET NULL,
    reviewed_at      TIMESTAMPTZ,
    created_at       TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Staff work for exactly ONE business: a vet clinic or a shelter.
-- can_manage_orders only matters for clinic staff (vet-owned medicine orders).
CREATE TABLE staff (
    id                SERIAL PRIMARY KEY,
    user_id           INT NOT NULL UNIQUE REFERENCES users(id) ON DELETE RESTRICT,
    vet_id            INT REFERENCES vets(id)     ON DELETE CASCADE,
    shelter_id        INT REFERENCES shelters(id) ON DELETE CASCADE,
    job_title         VARCHAR(100),
    can_manage_orders BOOLEAN NOT NULL DEFAULT FALSE,
    CHECK ((vet_id IS NOT NULL)::int + (shelter_id IS NOT NULL)::int = 1)
);

-- "Team" views: the owner account plus active staff of a business.
-- Use them to (a) send a notification to everyone who should see it and
-- (b) check "is this user allowed to act for this vet / shelter?".
CREATE VIEW vet_team AS
    SELECT v.id AS vet_id, v.user_id
      FROM vets v JOIN users u ON u.id = v.user_id
     WHERE u.is_active AND u.deleted_at IS NULL
    UNION
    SELECT s.vet_id, s.user_id
      FROM staff s JOIN users u ON u.id = s.user_id
     WHERE s.vet_id IS NOT NULL AND u.is_active AND u.deleted_at IS NULL;

CREATE VIEW shelter_team AS
    SELECT sh.id AS shelter_id, sh.user_id
      FROM shelters sh JOIN users u ON u.id = sh.user_id
     WHERE u.is_active AND u.deleted_at IS NULL
    UNION
    SELECT s.shelter_id, s.user_id
      FROM staff s JOIN users u ON u.id = s.user_id
     WHERE s.shelter_id IS NOT NULL AND u.is_active AND u.deleted_at IS NULL;

-- =====================================================================
-- 3. Vet availability and appointments
-- =====================================================================
-- Working hours are in the clinic's local time (vets.time_zone).
CREATE TABLE vet_availability (
    id          SERIAL PRIMARY KEY,
    vet_id      INT NOT NULL REFERENCES vets(id) ON DELETE CASCADE,
    weekday     SMALLINT NOT NULL CHECK (weekday BETWEEN 0 AND 6),   -- 0 = Sunday
    start_time  TIME NOT NULL,
    end_time    TIME NOT NULL,
    CHECK (end_time > start_time),
    UNIQUE (vet_id, weekday, start_time)
);

CREATE TABLE vet_time_off (
    id         SERIAL PRIMARY KEY,
    vet_id     INT NOT NULL REFERENCES vets(id) ON DELETE CASCADE,
    starts_at  TIMESTAMPTZ NOT NULL,
    ends_at    TIMESTAMPTZ NOT NULL,
    reason     VARCHAR(255),
    CHECK (ends_at > starts_at)
);

CREATE TABLE appointments (
    id                SERIAL PRIMARY KEY,
    owner_id          INT NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
    pet_id            INT NOT NULL,
    vet_id            INT NOT NULL REFERENCES vets(id)  ON DELETE RESTRICT,
    starts_at         TIMESTAMPTZ NOT NULL,
    ends_at           TIMESTAMPTZ NOT NULL,            -- API sets starts_at + vets.appointment_minutes
    reason            VARCHAR(255),
    status            VARCHAR(20) NOT NULL DEFAULT 'pending'
                      CHECK (status IN ('pending', 'confirmed', 'declined', 'cancelled', 'completed')),
    decline_reason    VARCHAR(255),
    handled_by        INT REFERENCES users(id) ON DELETE SET NULL,   -- the vet or staff member who answered
    reminder_sent_at  TIMESTAMPTZ,
    created_at        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CHECK (ends_at > starts_at),
    -- The pet must belong to the owner who is booking.
    FOREIGN KEY (pet_id, owner_id) REFERENCES pets(id, owner_id) ON DELETE RESTRICT,
    -- A vet cannot have two overlapping active bookings (10:00-10:30 and 10:15-10:45 are rejected).
    CONSTRAINT no_double_booking
        EXCLUDE USING gist (vet_id WITH =, tstzrange(starts_at, ends_at) WITH &&)
        WHERE (status IN ('pending', 'confirmed'))
);

-- =====================================================================
-- 4. Shelter boarding
-- =====================================================================
CREATE TABLE boarding_requests (
    id              SERIAL PRIMARY KEY,
    owner_id        INT NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
    pet_id          INT NOT NULL,
    shelter_id      INT NOT NULL REFERENCES shelters(id) ON DELETE RESTRICT,
    start_date      DATE NOT NULL,
    end_date        DATE NOT NULL,
    price_per_day   NUMERIC(10, 2) NOT NULL CHECK (price_per_day >= 0),   -- copied from the shelter at request time
    total_price     NUMERIC(10, 2) NOT NULL CHECK (total_price >= 0),
    status          VARCHAR(20) NOT NULL DEFAULT 'pending'
                    CHECK (status IN ('pending', 'accepted', 'declined', 'cancelled', 'completed')),
    decline_reason  VARCHAR(255),
    handled_by      INT REFERENCES users(id) ON DELETE SET NULL,          -- the shelter or staff member who answered
    notes           TEXT,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CHECK (end_date >= start_date),
    FOREIGN KEY (pet_id, owner_id) REFERENCES pets(id, owner_id) ON DELETE RESTRICT
);

-- Capacity check, day by day: accepting a request is refused if ANY night in its range is already full.
-- The shelter row is locked first, so two staff members accepting at the same moment cannot both pass.
CREATE FUNCTION enforce_shelter_capacity() RETURNS trigger AS $$
DECLARE
    cap       INT;
    peak_used INT;
BEGIN
    IF NEW.status <> 'accepted' THEN
        RETURN NEW;
    END IF;

    SELECT capacity INTO cap FROM shelters WHERE id = NEW.shelter_id FOR UPDATE;

    SELECT COALESCE(MAX(per_day.cnt), 0) INTO peak_used
      FROM (
            SELECT d, COUNT(b.id) AS cnt
              FROM generate_series(NEW.start_date::timestamp, NEW.end_date::timestamp, interval '1 day') AS d
              LEFT JOIN boarding_requests b
                     ON b.shelter_id = NEW.shelter_id
                    AND b.status = 'accepted'
                    AND b.id IS DISTINCT FROM NEW.id
                    AND d::date BETWEEN b.start_date AND b.end_date
             GROUP BY d
           ) AS per_day;

    IF peak_used >= cap THEN
        RAISE EXCEPTION 'Shelter is full for these dates' USING ERRCODE = '23514';
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_boarding_capacity
    BEFORE INSERT OR UPDATE OF status, start_date, end_date, shelter_id ON boarding_requests
    FOR EACH ROW EXECUTE FUNCTION enforce_shelter_capacity();

-- =====================================================================
-- 5. Shop (marketplace)
-- =====================================================================
-- seller_user_id is the account of a seller (food) or a vet (medicine, or food).
CREATE TABLE products (
    id                    SERIAL PRIMARY KEY,
    seller_user_id        INT NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
    name                  VARCHAR(150) NOT NULL,
    category              VARCHAR(20) NOT NULL CHECK (category IN ('food', 'medicine')),
    brand                 VARCHAR(100),
    target_species        VARCHAR(50),                  -- 'Dog', 'Cat', ... lets owners filter
    description           TEXT,
    price                 NUMERIC(10, 2) NOT NULL CHECK (price >= 0),
    stock                 INT NOT NULL DEFAULT 0 CHECK (stock >= 0),
    image_url             VARCHAR(255),
    prescription_required BOOLEAN NOT NULL DEFAULT FALSE,
    is_active             BOOLEAN NOT NULL DEFAULT TRUE,   -- "delete" = set FALSE, orders keep their history
    created_at            TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Only sellers and vets may own products, and only vets may sell medicine.
CREATE FUNCTION enforce_product_owner_role() RETURNS trigger AS $$
DECLARE
    owner_role VARCHAR(20);
BEGIN
    SELECT role INTO owner_role FROM users WHERE id = NEW.seller_user_id;
    IF owner_role NOT IN ('vet', 'seller') THEN
        RAISE EXCEPTION 'Only vets and sellers can list products' USING ERRCODE = '23514';
    END IF;
    IF NEW.category = 'medicine' AND owner_role <> 'vet' THEN
        RAISE EXCEPTION 'Only vets can sell medicine' USING ERRCODE = '23514';
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_product_owner_role
    BEFORE INSERT OR UPDATE OF seller_user_id, category ON products
    FOR EACH ROW EXECUTE FUNCTION enforce_product_owner_role();

-- A vet reviews an uploaded prescription (photo/PDF) before prescription-only items can be ordered.
CREATE TABLE prescriptions (
    id           SERIAL PRIMARY KEY,
    owner_id     INT NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
    pet_id       INT NOT NULL,
    vet_id       INT NOT NULL REFERENCES vets(id) ON DELETE RESTRICT,
    image_url    VARCHAR(255) NOT NULL,
    status       VARCHAR(20) NOT NULL DEFAULT 'pending'
                 CHECK (status IN ('pending', 'approved', 'rejected')),
    reviewed_by  INT REFERENCES users(id) ON DELETE SET NULL,
    reviewed_at  TIMESTAMPTZ,
    expires_on   DATE,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    FOREIGN KEY (pet_id, owner_id) REFERENCES pets(id, owner_id) ON DELETE RESTRICT
);

-- One order per seller. A mixed cart is split into several orders by the API.
-- The cart itself lives in the browser and is re-checked on the server at checkout.
CREATE TABLE orders (
    id               SERIAL PRIMARY KEY,
    owner_id         INT NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
    seller_user_id   INT NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
    status           VARCHAR(20) NOT NULL DEFAULT 'pending'
                     CHECK (status IN ('pending', 'accepted', 'packed',
                                       'out_for_delivery', 'delivered', 'cancelled')),
    cancel_reason    VARCHAR(255),
    delivery_address VARCHAR(255) NOT NULL,
    delivery_phone   VARCHAR(30)  NOT NULL,
    payment_method   VARCHAR(20)  NOT NULL DEFAULT 'cod' CHECK (payment_method IN ('cod')),
    delivery_fee     NUMERIC(10, 2) NOT NULL DEFAULT 0 CHECK (delivery_fee >= 0),
    total            NUMERIC(10, 2) NOT NULL CHECK (total >= 0),
    created_at       TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- product_name and unit_price are copied at purchase time, so later edits never change old orders.
CREATE TABLE order_items (
    id              SERIAL PRIMARY KEY,
    order_id        INT NOT NULL REFERENCES orders(id)   ON DELETE CASCADE,
    product_id      INT NOT NULL REFERENCES products(id) ON DELETE RESTRICT,
    product_name    VARCHAR(150) NOT NULL,
    quantity        INT NOT NULL CHECK (quantity > 0),
    unit_price      NUMERIC(10, 2) NOT NULL CHECK (unit_price >= 0),
    prescription_id INT REFERENCES prescriptions(id) ON DELETE RESTRICT
);

-- A prescription-only product needs an approved, unexpired prescription belonging to the buyer.
CREATE FUNCTION enforce_prescription() RETURNS trigger AS $$
DECLARE
    needs_rx   BOOLEAN;
    rx_is_good BOOLEAN;
BEGIN
    SELECT prescription_required INTO needs_rx FROM products WHERE id = NEW.product_id;
    IF needs_rx THEN
        SELECT EXISTS (
            SELECT 1
              FROM prescriptions p
              JOIN orders o ON o.id = NEW.order_id
             WHERE p.id = NEW.prescription_id
               AND p.status = 'approved'
               AND p.owner_id = o.owner_id
               AND (p.expires_on IS NULL OR p.expires_on >= CURRENT_DATE)
        ) INTO rx_is_good;
        IF NOT rx_is_good THEN
            RAISE EXCEPTION 'A valid approved prescription is required for this product' USING ERRCODE = '23514';
        END IF;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_order_item_prescription
    BEFORE INSERT ON order_items
    FOR EACH ROW EXECUTE FUNCTION enforce_prescription();

-- Stock rule (do this in the API, inside the same transaction as the order):
--   UPDATE products SET stock = stock - $qty WHERE id = $id AND stock >= $qty;
--   -> if 0 rows are updated, the item sold out: roll back and tell the user.
-- Never "read stock, then write stock". The CHECK (stock >= 0) above is only the safety net.

-- =====================================================================
-- 6. Chat (owner <-> shelter team) and notifications
-- =====================================================================
-- A conversation belongs to the SHELTER, not one person. Access = the owner, or anyone in shelter_team.
CREATE TABLE conversations (
    id                  SERIAL PRIMARY KEY,
    boarding_request_id INT NOT NULL UNIQUE REFERENCES boarding_requests(id) ON DELETE CASCADE,
    owner_id            INT NOT NULL REFERENCES users(id)    ON DELETE RESTRICT,
    shelter_id          INT NOT NULL REFERENCES shelters(id) ON DELETE RESTRICT,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE messages (
    id              SERIAL PRIMARY KEY,
    conversation_id INT NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
    sender_id       INT NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
    body            TEXT NOT NULL CHECK (length(body) BETWEEN 1 AND 2000),
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    read_at         TIMESTAMPTZ          -- set when the other side first opens it
);

-- One row per recipient. To notify a whole team, INSERT ... SELECT user_id FROM vet_team / shelter_team.
CREATE TABLE notifications (
    id          SERIAL PRIMARY KEY,
    user_id     INT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    type        VARCHAR(40) NOT NULL
                CHECK (type IN (
                    'appointment_requested', 'appointment_confirmed',
                    'appointment_declined',  'appointment_cancelled', 'appointment_reminder',
                    'boarding_requested', 'boarding_accepted', 'boarding_declined',
                    'order_placed', 'order_status_changed',
                    'prescription_requested', 'prescription_reviewed',
                    'approval_requested', 'account_approved', 'account_rejected',
                    'new_message'
                )),
    title       VARCHAR(150) NOT NULL,
    body        TEXT,
    link        VARCHAR(255),
    is_read     BOOLEAN NOT NULL DEFAULT FALSE,
    emailed_at  TIMESTAMPTZ,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- =====================================================================
-- 7. Reviews and pet health records
-- =====================================================================
-- A review is attached to ONE completed appointment OR ONE completed boarding stay,
-- so only real customers can review. (The API checks that status = 'completed'.)
CREATE TABLE reviews (
    id                  SERIAL PRIMARY KEY,
    author_id           INT NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
    appointment_id      INT UNIQUE REFERENCES appointments(id)      ON DELETE CASCADE,
    boarding_request_id INT UNIQUE REFERENCES boarding_requests(id) ON DELETE CASCADE,
    rating              SMALLINT NOT NULL CHECK (rating BETWEEN 1 AND 5),
    comment             TEXT,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CHECK ((appointment_id IS NOT NULL)::int + (boarding_request_id IS NOT NULL)::int = 1)
);

CREATE TABLE health_records (
    id             SERIAL PRIMARY KEY,
    pet_id         INT NOT NULL REFERENCES pets(id) ON DELETE CASCADE,
    record_type    VARCHAR(20) NOT NULL
                   CHECK (record_type IN ('vaccination', 'treatment', 'checkup', 'note')),
    title          VARCHAR(150) NOT NULL,
    details        TEXT,
    recorded_on    DATE NOT NULL DEFAULT CURRENT_DATE,
    next_due_on    DATE,                                    -- e.g. next vaccine, used for reminders
    appointment_id INT REFERENCES appointments(id) ON DELETE SET NULL,
    created_by     INT REFERENCES users(id) ON DELETE SET NULL,
    created_at     TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- =====================================================================
-- 8. Status history (who changed what, and when)
-- =====================================================================
-- The API sets the actor at the start of each transaction:
--   SELECT set_config('app.current_user_id', '42', true);
CREATE TABLE status_history (
    id           BIGSERIAL PRIMARY KEY,
    entity_type  VARCHAR(30) NOT NULL
                 CHECK (entity_type IN ('appointment', 'boarding_request', 'order', 'prescription')),
    entity_id    INT NOT NULL,
    old_status   VARCHAR(20),
    new_status   VARCHAR(20) NOT NULL,
    changed_by   INT REFERENCES users(id) ON DELETE SET NULL,
    changed_at   TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE FUNCTION log_status_change() RETURNS trigger AS $$
DECLARE
    actor INT;
BEGIN
    actor := NULLIF(current_setting('app.current_user_id', true), '')::INT;
    IF TG_OP = 'INSERT' THEN
        INSERT INTO status_history (entity_type, entity_id, old_status, new_status, changed_by)
        VALUES (TG_ARGV[0], NEW.id, NULL, NEW.status, actor);
    ELSIF NEW.status IS DISTINCT FROM OLD.status THEN
        INSERT INTO status_history (entity_type, entity_id, old_status, new_status, changed_by)
        VALUES (TG_ARGV[0], NEW.id, OLD.status, NEW.status, actor);
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_log_appointments
    AFTER INSERT OR UPDATE OF status ON appointments
    FOR EACH ROW EXECUTE FUNCTION log_status_change('appointment');
CREATE TRIGGER trg_log_boarding
    AFTER INSERT OR UPDATE OF status ON boarding_requests
    FOR EACH ROW EXECUTE FUNCTION log_status_change('boarding_request');
CREATE TRIGGER trg_log_orders
    AFTER INSERT OR UPDATE OF status ON orders
    FOR EACH ROW EXECUTE FUNCTION log_status_change('order');
CREATE TRIGGER trg_log_prescriptions
    AFTER INSERT OR UPDATE OF status ON prescriptions
    FOR EACH ROW EXECUTE FUNCTION log_status_change('prescription');

-- =====================================================================
-- 9. Public views (guests only ever read from these)
-- =====================================================================
-- Unapproved, suspended or deleted businesses never show up.
CREATE VIEW public_vets AS
    SELECT v.id, v.clinic_name, v.address, v.lat, v.lng, v.phone, v.opening_hours,
           v.image_url, v.appointment_minutes
      FROM vets v JOIN users u ON u.id = v.user_id
     WHERE v.approval_status = 'approved' AND u.is_active AND u.deleted_at IS NULL;

CREATE VIEW public_shelters AS
    SELECT s.id, s.name, s.address, s.lat, s.lng, s.phone, s.image_url,
           s.capacity, s.price_per_day
      FROM shelters s JOIN users u ON u.id = s.user_id
     WHERE s.approval_status = 'approved' AND u.is_active AND u.deleted_at IS NULL;

CREATE VIEW public_products AS
    SELECT p.id, p.seller_user_id, p.name, p.category, p.brand, p.target_species,
           p.description, p.price, p.stock, p.image_url, p.prescription_required
      FROM products p
      JOIN users u        ON u.id = p.seller_user_id
      LEFT JOIN vets v    ON v.user_id = u.id
      LEFT JOIN sellers s ON s.user_id = u.id
     WHERE p.is_active AND u.is_active AND u.deleted_at IS NULL
       AND ((u.role = 'vet'    AND v.approval_status = 'approved')
         OR (u.role = 'seller' AND s.approval_status = 'approved'));

CREATE VIEW vet_ratings AS
    SELECT a.vet_id, ROUND(AVG(r.rating), 2) AS avg_rating, COUNT(*) AS review_count
      FROM reviews r JOIN appointments a ON a.id = r.appointment_id
     GROUP BY a.vet_id;

CREATE VIEW shelter_ratings AS
    SELECT b.shelter_id, ROUND(AVG(r.rating), 2) AS avg_rating, COUNT(*) AS review_count
      FROM reviews r JOIN boarding_requests b ON b.id = r.boarding_request_id
     GROUP BY b.shelter_id;

-- =====================================================================
-- 10. Indexes
-- =====================================================================
CREATE INDEX idx_auth_tokens_user       ON auth_tokens(user_id, purpose);
CREATE INDEX idx_pets_owner             ON pets(owner_id) WHERE deleted_at IS NULL;
CREATE INDEX idx_vets_location          ON vets(lat, lng);
CREATE INDEX idx_shelters_location      ON shelters(lat, lng);
CREATE INDEX idx_vets_approval          ON vets(approval_status);
CREATE INDEX idx_shelters_approval      ON shelters(approval_status);
CREATE INDEX idx_sellers_approval       ON sellers(approval_status);
CREATE INDEX idx_staff_vet              ON staff(vet_id);
CREATE INDEX idx_staff_shelter          ON staff(shelter_id);
CREATE INDEX idx_vet_avail_vet          ON vet_availability(vet_id, weekday);
CREATE INDEX idx_vet_time_off           ON vet_time_off(vet_id, starts_at);
CREATE INDEX idx_appt_owner             ON appointments(owner_id, starts_at);
CREATE INDEX idx_appt_vet_status        ON appointments(vet_id, status, starts_at);
CREATE INDEX idx_appt_reminder          ON appointments(starts_at) WHERE status = 'confirmed' AND reminder_sent_at IS NULL;
CREATE INDEX idx_boarding_shelter       ON boarding_requests(shelter_id, status, start_date);
CREATE INDEX idx_boarding_owner         ON boarding_requests(owner_id);
CREATE INDEX idx_products_seller        ON products(seller_user_id, is_active);
CREATE INDEX idx_products_filter        ON products(category, target_species) WHERE is_active;
CREATE INDEX idx_prescriptions_vet      ON prescriptions(vet_id, status);
CREATE INDEX idx_orders_owner           ON orders(owner_id, created_at DESC);
CREATE INDEX idx_orders_seller          ON orders(seller_user_id, status);
CREATE INDEX idx_order_items_order      ON order_items(order_id);
CREATE INDEX idx_messages_conv_time     ON messages(conversation_id, created_at);
CREATE INDEX idx_notif_user_unread      ON notifications(user_id, is_read, created_at DESC);
CREATE INDEX idx_health_pet             ON health_records(pet_id, recorded_on DESC);
CREATE INDEX idx_health_due             ON health_records(next_due_on) WHERE next_due_on IS NOT NULL;
CREATE INDEX idx_status_history_entity  ON status_history(entity_type, entity_id, changed_at);