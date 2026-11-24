-- ICT371 - Question 5: Hostel Room Allocation
CREATE SCHEMA IF NOT EXISTS q5_hostel;
SET search_path TO q5_hostel, public;

CREATE TABLE students (
    student_id SERIAL PRIMARY KEY,
    student_number VARCHAR(20) NOT NULL UNIQUE,
    full_name VARCHAR(100) NOT NULL
);
CREATE TABLE rooms (
    room_id SERIAL PRIMARY KEY,
    room_number VARCHAR(20) NOT NULL UNIQUE,
    capacity INTEGER NOT NULL CHECK (capacity > 0)
);
CREATE TABLE allocations (
    allocation_id SERIAL PRIMARY KEY,
    student_id INTEGER NOT NULL REFERENCES students(student_id),
    room_id INTEGER NOT NULL REFERENCES rooms(room_id),
    allocated_on DATE NOT NULL,
    released_on DATE,
    status VARCHAR(10) NOT NULL CHECK(status IN ('ACTIVE','ENDED')),
    CHECK ((status='ACTIVE' AND released_on IS NULL) OR
           (status='ENDED' AND released_on IS NOT NULL))
);
CREATE TABLE occupancy_snapshot (
    snapshot_date DATE NOT NULL,
    room_id INTEGER NOT NULL REFERENCES rooms(room_id),
    occupied_beds INTEGER NOT NULL,
    free_beds INTEGER NOT NULL,
    PRIMARY KEY(snapshot_date,room_id)
);

INSERT INTO students(student_number,full_name) VALUES
('ST101','Mary Banda'),('ST102','Brian Phiri'),('ST103','Chipo Mwansa'),
('ST104','David Tembo'),('ST105','Esther Zulu');
INSERT INTO rooms(room_number,capacity) VALUES ('A1',2),('A2',3),('A3',2);
INSERT INTO allocations(student_id,room_id,allocated_on,released_on,status) VALUES
(1,1,CURRENT_DATE,NULL,'ACTIVE'),
(2,1,CURRENT_DATE,NULL,'ACTIVE'),
(3,2,CURRENT_DATE,NULL,'ACTIVE'),
(4,2,CURRENT_DATE,NULL,'ACTIVE'),
(5,2,CURRENT_DATE-30,CURRENT_DATE-2,'ENDED');

-- 5(b) Free beds function
CREATE OR REPLACE FUNCTION fn_free_beds(p_room_id INTEGER)
RETURNS INTEGER LANGUAGE plpgsql AS $$
DECLARE v_capacity INTEGER; v_occupied INTEGER;
BEGIN
    SELECT capacity INTO v_capacity FROM rooms WHERE room_id=p_room_id;
    IF NOT FOUND THEN RAISE EXCEPTION 'Unknown room ID: %',p_room_id; END IF;
    SELECT COUNT(*) INTO v_occupied FROM allocations
    WHERE room_id=p_room_id AND status='ACTIVE';
    RETURN v_capacity-v_occupied;
END;
$$;

-- 5(d) Trigger also protects direct INSERT/UPDATE and locks room to serialize capacity checks
CREATE OR REPLACE FUNCTION fn_enforce_allocation_rules()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE v_capacity INTEGER; v_occupied INTEGER;
BEGIN
    IF NEW.status='ACTIVE' THEN
        SELECT capacity INTO v_capacity FROM rooms WHERE room_id=NEW.room_id FOR UPDATE;
        IF NOT FOUND THEN RAISE EXCEPTION 'Unknown room ID'; END IF;

        PERFORM 1 FROM allocations
        WHERE student_id=NEW.student_id AND status='ACTIVE'
          AND allocation_id <> COALESCE(NEW.allocation_id,-1);
        IF FOUND THEN RAISE EXCEPTION 'Student already has an ACTIVE allocation'; END IF;

        SELECT COUNT(*) INTO v_occupied FROM allocations
        WHERE room_id=NEW.room_id AND status='ACTIVE'
          AND allocation_id <> COALESCE(NEW.allocation_id,-1);
        IF v_occupied >= v_capacity THEN RAISE EXCEPTION 'Room is full'; END IF;
        NEW.released_on := NULL;
    ELSIF NEW.status='ENDED' AND NEW.released_on IS NULL THEN
        RAISE EXCEPTION 'ENDED allocation requires released_on';
    END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER trg_allocation_rules
BEFORE INSERT OR UPDATE ON allocations
FOR EACH ROW EXECUTE FUNCTION fn_enforce_allocation_rules();

-- 5(c) Allocation procedure
CREATE OR REPLACE PROCEDURE pr_allocate_room(
    p_student_id INTEGER,p_room_id INTEGER,p_allocated_on DATE
)
LANGUAGE plpgsql AS $$
BEGIN
    IF NOT EXISTS(SELECT 1 FROM students WHERE student_id=p_student_id) THEN
        RAISE EXCEPTION 'Unknown student ID';
    END IF;
    IF NOT EXISTS(SELECT 1 FROM rooms WHERE room_id=p_room_id) THEN
        RAISE EXCEPTION 'Unknown room ID';
    END IF;
    IF p_allocated_on IS NULL THEN RAISE EXCEPTION 'Allocation date is required'; END IF;
    IF EXISTS(SELECT 1 FROM allocations WHERE student_id=p_student_id AND status='ACTIVE') THEN
        RAISE EXCEPTION 'Student already has an ACTIVE allocation';
    END IF;
    IF fn_free_beds(p_room_id)<=0 THEN RAISE EXCEPTION 'Room is full'; END IF;
    INSERT INTO allocations(student_id,room_id,allocated_on,released_on,status)
    VALUES(p_student_id,p_room_id,p_allocated_on,NULL,'ACTIVE');
END;
$$;

-- 5(e) Include empty rooms
CREATE OR REPLACE VIEW v_room_occupancy AS
SELECT r.room_id,r.room_number,r.capacity,
       COUNT(a.allocation_id) FILTER(WHERE a.status='ACTIVE')::INTEGER AS occupied_beds,
       r.capacity-COUNT(a.allocation_id) FILTER(WHERE a.status='ACTIVE')::INTEGER AS free_beds
FROM rooms r LEFT JOIN allocations a ON a.room_id=r.room_id
GROUP BY r.room_id,r.room_number,r.capacity;
SELECT * FROM v_room_occupancy;

-- 5(f) Partial index for active allocations by room
CREATE INDEX idx_allocations_active_room ON allocations(room_id)
WHERE status='ACTIVE';
EXPLAIN SELECT * FROM allocations WHERE room_id=1 AND status='ACTIVE';

-- 5(g) Daily occupancy snapshot, one row per room/date
CREATE OR REPLACE PROCEDURE pr_refresh_occupancy()
LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO occupancy_snapshot(snapshot_date,room_id,occupied_beds,free_beds)
    SELECT CURRENT_DATE,r.room_id,
      COUNT(a.allocation_id) FILTER(WHERE a.status='ACTIVE')::INTEGER,
      r.capacity-COUNT(a.allocation_id) FILTER(WHERE a.status='ACTIVE')::INTEGER
    FROM rooms r LEFT JOIN allocations a ON a.room_id=r.room_id
    GROUP BY r.room_id,r.capacity
    ON CONFLICT(snapshot_date,room_id) DO UPDATE SET
      occupied_beds=EXCLUDED.occupied_beds,free_beds=EXCLUDED.free_beds;
END;
$$;

-- Scheduling requires pg_cron to be installed and enabled by the PostgreSQL administrator.
CREATE EXTENSION IF NOT EXISTS pg_cron;
SELECT cron.schedule('q5-refresh-occupancy','55 23 * * *',
    $$CALL q5_hostel.pr_refresh_occupancy()$$);

CALL pr_refresh_occupancy();
SELECT * FROM occupancy_snapshot;
