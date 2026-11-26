-- DEVELOPMENT ONLY. Never run this in production.
-- Run after migrations 001-004 on an EMPTY database
-- (the vets below use accepts_emergencies and emergency_phone, which come from 003).
--
-- password_hash values are placeholders. Create real accounts through the API (bcrypt),
-- and create the first admin with a script, never through public signup.

INSERT INTO users (name, email, password_hash, role, phone, email_verified_at) VALUES
  ('Demo Owner',      'owner@example.com',        'placeholder-hash', 'owner',   '0771234567', NOW()),  -- 1
  ('Dr. Perera',      'vet1@example.com',         'placeholder-hash', 'vet',     '0112000001', NOW()),  -- 2
  ('Dr. Silva',       'vet2@example.com',         'placeholder-hash', 'vet',     '0812000002', NOW()),  -- 3
  ('Happy Paws',      'shelter@example.com',      'placeholder-hash', 'shelter', '0777654321', NOW()),  -- 4
  ('Paws Pet Foods',  'seller@example.com',       'placeholder-hash', 'seller',  '0779998888', NOW()),  -- 5
  ('Site Admin',      'admin@example.com',        'placeholder-hash', 'admin',   NULL,         NOW()),  -- 6
  ('Nimali (Clinic)', 'clinicstaff@example.com',  'placeholder-hash', 'staff',   '0112000011', NOW()),  -- 7
  ('Kamal (Shelter)', 'shelterstaff@example.com', 'placeholder-hash', 'staff',   '0777654322', NOW()),  -- 8
  ('Dr. Fernando',    'vet3@example.com',         'placeholder-hash', 'vet',     '0912000004', NOW());  -- 9

INSERT INTO pets (owner_id, name, species, breed, age, medical_notes) VALUES
  (1, 'Bruno', 'Dog', 'Labrador', 3, 'Vaccinated, no allergies'),   -- 1
  (1, 'Mimi',  'Cat', 'Persian',  2, 'Needs special food');         -- 2

-- Vet 1 is approved. Vet 2 is still pending, so use it to test the admin approval queue.
-- Vets 1 and 3 take emergencies, so /api/emergency/nearest has two clinics to sort by distance.
INSERT INTO vets (user_id, clinic_name, address, lat, lng, phone, opening_hours,
                  appointment_minutes, approval_status, reviewed_by, reviewed_at,
                  accepts_emergencies, emergency_phone) VALUES
  (2, 'City Pet Clinic',   '12 Main Street, Colombo 03', 6.9271, 79.8612, '0112000001', 'Mon-Sat 8am-6pm', 30, 'approved', 6,    NOW(), TRUE,  '0112000001'),  -- 1
  (3, 'Green Valley Vets', '45 Lake Road, Kandy',        7.2906, 80.6337, '0812000002', 'Mon-Fri 9am-5pm', 30, 'pending',  NULL, NULL,  FALSE, NULL),          -- 2
  (9, 'PetCare 24/7',      '3 Beach Road, Galle',        6.0535, 80.2210, '0912000004', 'Open 24 hours',   30, 'approved', 6,    NOW(), TRUE,  '0912000004'); -- 3

INSERT INTO shelters (user_id, name, address, lat, lng, phone, capacity, price_per_day,
                      approval_status, reviewed_by, reviewed_at) VALUES
  (4, 'Happy Paws Shelter', '22 Garden Lane, Colombo 05', 6.8900, 79.8650, '0777654321', 20, 1500.00, 'approved', 6, NOW());

INSERT INTO sellers (user_id, store_name, address, phone, delivery_fee,
                     approval_status, reviewed_by, reviewed_at) VALUES
  (5, 'Paws Pet Foods', '7 Market Road, Colombo 10', '0779998888', 250.00, 'approved', 6, NOW());

INSERT INTO staff (user_id, vet_id, shelter_id, job_title, can_manage_orders) VALUES
  (7, 1,    NULL, 'Receptionist',      FALSE),
  (8, NULL, 1,    'Shelter assistant', FALSE);

-- Weekly working hours (0 = Sunday)
INSERT INTO vet_availability (vet_id, weekday, start_time, end_time)
    SELECT 1, d, '08:00', '18:00' FROM generate_series(1, 6) AS d;   -- Mon-Sat
INSERT INTO vet_availability (vet_id, weekday, start_time, end_time)
    SELECT 2, d, '09:00', '17:00' FROM generate_series(1, 5) AS d;   -- Mon-Fri

INSERT INTO products (seller_user_id, name, category, brand, target_species, description,
                      price, stock, prescription_required) VALUES
  (5, 'Dry Dog Food 3kg',  'food',     'PawsChoice', 'Dog', 'Chicken and rice',          4200.00, 40, FALSE),  -- 1
  (5, 'Cat Food Tuna 1kg', 'food',     'PawsChoice', 'Cat', 'Adult cats',                2600.00, 25, FALSE),  -- 2
  (2, 'Dewormer Tablets',  'medicine', 'VetCare',    NULL,  'Broad spectrum dewormer',    950.00, 60, FALSE),  -- 3
  (2, 'Antibiotic Course', 'medicine', 'VetCare',    'Dog', 'Prescription only',         3200.00, 15, TRUE);   -- 4

-- One pending booking for the clinic (starts two days from now, 30 minutes)
INSERT INTO appointments (owner_id, pet_id, vet_id, starts_at, ends_at, reason, status) VALUES
  (1, 1, 1, date_trunc('hour', NOW() + INTERVAL '2 days'),
            date_trunc('hour', NOW() + INTERVAL '2 days') + INTERVAL '30 minutes',
   'Annual vaccination', 'pending');

-- Five nights (inclusive): 5 x 1500 = 7500
INSERT INTO boarding_requests (owner_id, pet_id, shelter_id, start_date, end_date,
                               price_per_day, total_price, status, notes) VALUES
  (1, 2, 1, CURRENT_DATE + 10, CURRENT_DATE + 14, 1500.00, 7500.00, 'pending', 'Feed twice a day');

INSERT INTO prescriptions (owner_id, pet_id, vet_id, image_url, status) VALUES
  (1, 1, 1, 'https://example.com/prescription-demo.jpg', 'pending');

INSERT INTO orders (owner_id, seller_user_id, status, delivery_address, delivery_phone, delivery_fee, total) VALUES
  (1, 5, 'pending', '15 Flower Road, Colombo 07', '0771234567', 250.00, 4450.00);

INSERT INTO order_items (order_id, product_id, product_name, quantity, unit_price) VALUES
  (1, 1, 'Dry Dog Food 3kg', 1, 4200.00);

INSERT INTO conversations (boarding_request_id, owner_id, shelter_id) VALUES (1, 1, 1);

INSERT INTO messages (conversation_id, sender_id, body) VALUES
  (1, 1, 'Hi, my cat Mimi needs special food. Is that okay?'),
  (1, 4, 'Yes, please bring it along and we will take good care of her.');

-- Team notifications: everyone on the business team gets the alert.
INSERT INTO notifications (user_id, type, title, body, link)
    SELECT user_id, 'appointment_requested', 'New appointment request',
           'Demo Owner requested a slot for Bruno.', '/vet/appointments/1'
      FROM vet_team WHERE vet_id = 1;                               -- Dr. Perera + clinic receptionist

INSERT INTO notifications (user_id, type, title, body, link)
    SELECT user_id, 'boarding_requested', 'New boarding request',
           'Demo Owner wants to board Mimi for 5 nights.', '/shelter/requests/1'
      FROM shelter_team WHERE shelter_id = 1;                       -- Happy Paws + shelter assistant

INSERT INTO notifications (user_id, type, title, body, link) VALUES
  (5, 'order_placed',          'New order',               'Order #1 from Demo Owner.', '/seller/orders/1'),
  (6, 'approval_requested',    'New vet awaiting approval', 'Green Valley Vets is waiting in the approval queue.', '/admin/approvals');