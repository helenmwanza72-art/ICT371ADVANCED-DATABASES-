-- ICT371 - Question 8: Transport Fleet Maintenance
CREATE SCHEMA IF NOT EXISTS q8_transport;
SET search_path TO q8_transport, public;

CREATE TABLE vehicles (
    vehicle_id SERIAL PRIMARY KEY,
    registration VARCHAR(20) NOT NULL UNIQUE,
    current_odometer NUMERIC(12,2) NOT NULL CHECK(current_odometer>=0),
    last_service_odometer NUMERIC(12,2) NOT NULL CHECK(last_service_odometer>=0),
    CHECK(last_service_odometer<=current_odometer)
);
CREATE TABLE trips (
    trip_id SERIAL PRIMARY KEY,
    vehicle_id INTEGER NOT NULL REFERENCES vehicles(vehicle_id),
    trip_on DATE NOT NULL,
    start_odometer NUMERIC(12,2) NOT NULL CHECK(start_odometer>=0),
    end_odometer NUMERIC(12,2) NOT NULL CHECK(end_odometer>start_odometer)
);
CREATE TABLE service_alerts (
    vehicle_id INTEGER PRIMARY KEY REFERENCES vehicles(vehicle_id),
    km_since_service NUMERIC(12,2) NOT NULL,
    flagged_on DATE NOT NULL
);

INSERT INTO vehicles(registration,current_odometer,last_service_odometer) VALUES
('ZMB-100A',12000,8000),('ZMB-200B',25000,21000),('ZMB-300C',40000,34000);

-- 8(b) Service due function
CREATE OR REPLACE FUNCTION fn_service_due(p_vehicle_id INTEGER)
RETURNS BOOLEAN LANGUAGE plpgsql AS $$
DECLARE v_current NUMERIC(12,2); v_service NUMERIC(12,2);
BEGIN
    SELECT current_odometer,last_service_odometer INTO v_current,v_service
    FROM vehicles WHERE vehicle_id=p_vehicle_id;
    IF NOT FOUND THEN RAISE EXCEPTION 'Unknown vehicle ID: %',p_vehicle_id; END IF;
    RETURN (v_current-v_service)>=5000;
END;
$$;

-- 8(d) Trigger validates start and updates odometer exactly once
CREATE OR REPLACE FUNCTION fn_update_vehicle_odometer()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE v_current NUMERIC(12,2);
BEGIN
    SELECT current_odometer INTO v_current FROM vehicles
    WHERE vehicle_id=NEW.vehicle_id FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'Unknown vehicle ID'; END IF;
    IF NEW.start_odometer<>v_current THEN
        RAISE EXCEPTION 'Trip start must equal vehicle current odometer (%)',v_current;
    END IF;
    IF NEW.end_odometer<=NEW.start_odometer THEN
        RAISE EXCEPTION 'Trip end must exceed trip start';
    END IF;
    UPDATE vehicles SET current_odometer=NEW.end_odometer
    WHERE vehicle_id=NEW.vehicle_id;
    RETURN NEW;
END;
$$;
CREATE TRIGGER trg_trip_odometer
BEFORE INSERT ON trips
FOR EACH ROW EXECUTE FUNCTION fn_update_vehicle_odometer();

-- 8(c) Procedure does not update vehicle; trigger performs the update
CREATE OR REPLACE PROCEDURE pr_record_trip(
    p_vehicle_id INTEGER,p_trip_on DATE,p_start NUMERIC,p_end NUMERIC
)
LANGUAGE plpgsql AS $$
BEGIN
    IF NOT EXISTS(SELECT 1 FROM vehicles WHERE vehicle_id=p_vehicle_id) THEN
        RAISE EXCEPTION 'Unknown vehicle ID';
    END IF;
    IF p_trip_on IS NULL OR p_start IS NULL OR p_end IS NULL OR p_end<=p_start THEN
        RAISE EXCEPTION 'Invalid trip date or odometer values';
    END IF;
    INSERT INTO trips(vehicle_id,trip_on,start_odometer,end_odometer)
    VALUES(p_vehicle_id,p_trip_on,p_start,p_end);
END;
$$;

-- Six trips added through procedure after trigger installation
CALL pr_record_trip(1,CURRENT_DATE,12000,12500);
CALL pr_record_trip(1,CURRENT_DATE,12500,13000);
CALL pr_record_trip(2,CURRENT_DATE,25000,25500);
CALL pr_record_trip(2,CURRENT_DATE,25500,26000);
CALL pr_record_trip(3,CURRENT_DATE,40000,40500);
CALL pr_record_trip(3,CURRENT_DATE,40500,41000);

-- 8(e) View
CREATE OR REPLACE VIEW v_service_due AS
SELECT registration,(current_odometer-last_service_odometer) AS km_since_service
FROM vehicles
WHERE current_odometer-last_service_odometer>=5000;
SELECT * FROM v_service_due;

-- 8(f) Index and matching query
CREATE INDEX idx_trips_vehicle_trip_on ON trips(vehicle_id,trip_on);
EXPLAIN SELECT * FROM trips
WHERE vehicle_id=1 AND trip_on BETWEEN CURRENT_DATE-30 AND CURRENT_DATE;

-- 8(g) Upsert due alerts and remove alerts for vehicles no longer due
CREATE OR REPLACE PROCEDURE pr_refresh_service_alerts()
LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO service_alerts(vehicle_id,km_since_service,flagged_on)
    SELECT vehicle_id,current_odometer-last_service_odometer,CURRENT_DATE
    FROM vehicles WHERE current_odometer-last_service_odometer>=5000
    ON CONFLICT(vehicle_id) DO UPDATE SET
      km_since_service=EXCLUDED.km_since_service,
      flagged_on=EXCLUDED.flagged_on;

    DELETE FROM service_alerts a
    USING vehicles v
    WHERE a.vehicle_id=v.vehicle_id
      AND v.current_odometer-v.last_service_odometer<5000;
END;
$$;

CREATE EXTENSION IF NOT EXISTS pg_cron;
SELECT cron.schedule('q8-refresh-service-alerts','0 6 * * 1',
    $$CALL q8_transport.pr_refresh_service_alerts()$$);

CALL pr_refresh_service_alerts();
SELECT * FROM vehicles;
SELECT * FROM trips;
SELECT * FROM service_alerts;
