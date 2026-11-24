-- ICT371 - Question 4: Clinic Appointment Scheduling
CREATE SCHEMA IF NOT EXISTS q4_clinic;
SET search_path TO q4_clinic, public;

CREATE TABLE patients (
    patient_id SERIAL PRIMARY KEY,
    full_name VARCHAR(100) NOT NULL
);
CREATE TABLE doctors (
    doctor_id SERIAL PRIMARY KEY,
    full_name VARCHAR(100) NOT NULL
);
CREATE TABLE appointments (
    appointment_id SERIAL PRIMARY KEY,
    patient_id INTEGER NOT NULL REFERENCES patients(patient_id),
    doctor_id INTEGER NOT NULL REFERENCES doctors(doctor_id),
    appointment_day DATE NOT NULL,
    slot_time TIME NOT NULL CHECK (slot_time IN (TIME '09:00',TIME '10:00',TIME '11:00',TIME '12:00')),
    status VARCHAR(10) NOT NULL DEFAULT 'BOOKED'
        CHECK (status IN ('BOOKED','ATTENDED','CANCELLED'))
);
CREATE TABLE clinic_summary (
    summary_date DATE PRIMARY KEY,
    booked_count INTEGER NOT NULL,
    attended_count INTEGER NOT NULL,
    cancelled_count INTEGER NOT NULL
);

INSERT INTO patients(full_name) VALUES ('Mary Banda'),('Brian Phiri'),('Chipo Mwansa');
INSERT INTO doctors(full_name) VALUES ('Dr. Phiri'),('Dr. Banda'),('Dr. Zulu');
INSERT INTO appointments(patient_id,doctor_id,appointment_day,slot_time,status) VALUES
(1,1,CURRENT_DATE, TIME '09:00','BOOKED'),
(2,1,CURRENT_DATE, TIME '10:00','ATTENDED'),
(3,2,CURRENT_DATE, TIME '09:00','BOOKED'),
(1,2,CURRENT_DATE, TIME '11:00','CANCELLED'),
(2,3,CURRENT_DATE, TIME '12:00','BOOKED'),
(3,3,CURRENT_DATE+1, TIME '09:00','BOOKED');

-- 4(b) Function
CREATE OR REPLACE FUNCTION fn_daily_load(p_doctor_id INTEGER,p_day DATE)
RETURNS INTEGER LANGUAGE plpgsql AS $$
DECLARE v_count INTEGER;
BEGIN
    PERFORM 1 FROM doctors WHERE doctor_id=p_doctor_id;
    IF NOT FOUND THEN RAISE EXCEPTION 'Unknown doctor ID: %',p_doctor_id; END IF;
    IF p_day IS NULL THEN RAISE EXCEPTION 'Appointment date is required'; END IF;
    SELECT COUNT(*) INTO v_count FROM appointments
    WHERE doctor_id=p_doctor_id AND appointment_day=p_day AND status <> 'CANCELLED';
    RETURN v_count;
END;
$$;

-- 4(d) Trigger prevents two non-cancelled appointments at the same doctor/date/slot
CREATE OR REPLACE FUNCTION fn_check_appointment_clash()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.status <> 'CANCELLED' THEN
        PERFORM 1 FROM appointments
        WHERE doctor_id=NEW.doctor_id
          AND appointment_day=NEW.appointment_day
          AND slot_time=NEW.slot_time
          AND status <> 'CANCELLED'
          AND appointment_id <> COALESCE(NEW.appointment_id,-1);
        IF FOUND THEN RAISE EXCEPTION 'Doctor already has a non-cancelled appointment in this slot'; END IF;
    END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER trg_appointment_clash
BEFORE INSERT OR UPDATE ON appointments
FOR EACH ROW EXECUTE FUNCTION fn_check_appointment_clash();

-- 4(c) Booking procedure
CREATE OR REPLACE PROCEDURE pr_book_appointment(
    p_patient_id INTEGER,p_doctor_id INTEGER,p_day DATE,p_slot TIME
)
LANGUAGE plpgsql AS $$
BEGIN
    IF NOT EXISTS(SELECT 1 FROM patients WHERE patient_id=p_patient_id) THEN
        RAISE EXCEPTION 'Unknown patient ID';
    END IF;
    IF NOT EXISTS(SELECT 1 FROM doctors WHERE doctor_id=p_doctor_id) THEN
        RAISE EXCEPTION 'Unknown doctor ID';
    END IF;
    IF p_day IS NULL OR p_day < CURRENT_DATE THEN RAISE EXCEPTION 'Appointment date cannot be in the past'; END IF;
    IF p_slot IS NULL OR p_slot NOT IN (TIME '09:00',TIME '10:00',TIME '11:00',TIME '12:00') THEN
        RAISE EXCEPTION 'Unsupported appointment slot';
    END IF;
    INSERT INTO appointments(patient_id,doctor_id,appointment_day,slot_time,status)
    VALUES(p_patient_id,p_doctor_id,p_day,p_slot,'BOOKED');
END;
$$;

-- 4(e) Today's booked appointments only
CREATE OR REPLACE VIEW v_today_appointments AS
SELECT a.appointment_id,p.full_name AS patient_name,
       d.full_name AS doctor_name,a.slot_time
FROM appointments a
JOIN patients p ON p.patient_id=a.patient_id
JOIN doctors d ON d.doctor_id=a.doctor_id
WHERE a.appointment_day=CURRENT_DATE AND a.status='BOOKED';
SELECT * FROM v_today_appointments;

-- 4(f) Index
CREATE INDEX idx_appointments_day_doctor ON appointments(appointment_day,doctor_id);
EXPLAIN SELECT * FROM appointments
WHERE appointment_day=CURRENT_DATE AND doctor_id=1;

-- 4(g) Daily status summary
CREATE OR REPLACE PROCEDURE pr_refresh_clinic_summary(p_day DATE)
LANGUAGE plpgsql AS $$
BEGIN
    IF p_day IS NULL THEN RAISE EXCEPTION 'Summary date is required'; END IF;
    INSERT INTO clinic_summary(summary_date,booked_count,attended_count,cancelled_count)
    SELECT p_day,
      COUNT(*) FILTER(WHERE status='BOOKED'),
      COUNT(*) FILTER(WHERE status='ATTENDED'),
      COUNT(*) FILTER(WHERE status='CANCELLED')
    FROM appointments WHERE appointment_day=p_day
    ON CONFLICT(summary_date) DO UPDATE SET
      booked_count=EXCLUDED.booked_count,
      attended_count=EXCLUDED.attended_count,
      cancelled_count=EXCLUDED.cancelled_count;
END;
$$;

-- Scheduling requires pg_cron to be installed and enabled by the PostgreSQL administrator.
CREATE EXTENSION IF NOT EXISTS pg_cron;
SELECT cron.schedule('q4-refresh-clinic-summary','0 1 * * *',
    $$CALL q4_clinic.pr_refresh_clinic_summary(CURRENT_DATE - 1)$$);

CALL pr_refresh_clinic_summary(CURRENT_DATE);
SELECT * FROM appointments;
SELECT * FROM clinic_summary;
