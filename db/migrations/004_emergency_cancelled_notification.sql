-- Migration 004: a notification type for "the owner cancelled the emergency".
ALTER TABLE notifications DROP CONSTRAINT notifications_type_check;
ALTER TABLE notifications ADD CONSTRAINT notifications_type_check
    CHECK (type IN (
        'appointment_requested', 'appointment_confirmed',
        'appointment_declined',  'appointment_cancelled', 'appointment_reminder',
        'boarding_requested', 'boarding_accepted', 'boarding_declined',
        'order_placed', 'order_status_changed',
        'prescription_requested', 'prescription_reviewed',
        'approval_requested', 'account_approved', 'account_rejected',
        'emergency_alert', 'emergency_accepted', 'emergency_declined',
        'emergency_no_response', 'emergency_cancelled',
        'new_message'
    ));