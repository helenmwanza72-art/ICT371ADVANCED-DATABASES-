-- ICT371 - Question 7: Water Meter Readings and Billing
CREATE SCHEMA IF NOT EXISTS q7_water;
SET search_path TO q7_water, public;

CREATE TABLE customers (
    customer_id SERIAL PRIMARY KEY,
    full_name VARCHAR(100) NOT NULL
);
CREATE TABLE readings (
    reading_id SERIAL PRIMARY KEY,
    customer_id INTEGER NOT NULL REFERENCES customers(customer_id),
    reading_month DATE NOT NULL CHECK(EXTRACT(DAY FROM reading_month)=1),
    previous_reading NUMERIC(12,2) NOT NULL CHECK(previous_reading>=0),
    current_reading NUMERIC(12,2) NOT NULL CHECK(current_reading>=0),
    UNIQUE(customer_id,reading_month)
);
CREATE TABLE bills (
    bill_id SERIAL PRIMARY KEY,
    reading_id INTEGER NOT NULL UNIQUE REFERENCES readings(reading_id),
    charge NUMERIC(12,2) NOT NULL CHECK(charge>=0),
    amount_paid NUMERIC(12,2) NOT NULL DEFAULT 0 CHECK(amount_paid>=0 AND amount_paid<=charge),
    due_on DATE NOT NULL
);
CREATE TABLE receivable_snapshot (
    snapshot_date DATE PRIMARY KEY,
    total_due NUMERIC(14,2) NOT NULL
);

INSERT INTO customers(full_name) VALUES ('Mary Banda'),('Brian Phiri'),('Chipo Mwansa');

-- 7(d) Reading validation trigger
CREATE OR REPLACE FUNCTION fn_validate_reading()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.current_reading < NEW.previous_reading THEN
        RAISE EXCEPTION 'Current meter reading cannot be below previous reading';
    END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER trg_validate_reading
BEFORE INSERT OR UPDATE ON readings
FOR EACH ROW EXECUTE FUNCTION fn_validate_reading();

INSERT INTO readings(customer_id,reading_month,previous_reading,current_reading) VALUES
(1,DATE '2026-01-01',100,100),
(1,DATE '2026-02-01',100,110),
(2,DATE '2026-01-01',200,215),
(2,DATE '2026-02-01',215,230),
(3,DATE '2026-01-01',50,65),
(3,DATE '2026-02-01',65,90);

-- 7(b) Tariff function: first 10 units K5 each, remaining units K8 each
CREATE OR REPLACE FUNCTION fn_water_charge(p_units NUMERIC)
RETURNS NUMERIC(12,2) LANGUAGE plpgsql AS $$
BEGIN
    IF p_units IS NULL OR p_units<0 THEN RAISE EXCEPTION 'Consumption must be non-negative'; END IF;
    RETURN (LEAST(p_units,10)*5 + GREATEST(p_units-10,0)*8)::NUMERIC(12,2);
END;
$$;

-- 7(c) Bill procedure
CREATE OR REPLACE PROCEDURE pr_generate_bill(p_reading_id INTEGER,p_due_on DATE)
LANGUAGE plpgsql AS $$
DECLARE v_previous NUMERIC(12,2); v_current NUMERIC(12,2); v_charge NUMERIC(12,2);
BEGIN
    IF p_due_on IS NULL THEN RAISE EXCEPTION 'Due date is required'; END IF;
    SELECT previous_reading,current_reading INTO v_previous,v_current
    FROM readings WHERE reading_id=p_reading_id;
    IF NOT FOUND THEN RAISE EXCEPTION 'Unknown reading ID: %',p_reading_id; END IF;
    IF EXISTS(SELECT 1 FROM bills WHERE reading_id=p_reading_id) THEN
        RAISE EXCEPTION 'A bill already exists for this reading';
    END IF;
    v_charge := fn_water_charge(v_current-v_previous);
    INSERT INTO bills(reading_id,charge,amount_paid,due_on)
    VALUES(p_reading_id,v_charge,0,p_due_on);
END;
$$;

-- Generate six bills
CALL pr_generate_bill(1,CURRENT_DATE+30);
CALL pr_generate_bill(2,CURRENT_DATE+30);
CALL pr_generate_bill(3,CURRENT_DATE+30);
CALL pr_generate_bill(4,CURRENT_DATE+30);
CALL pr_generate_bill(5,CURRENT_DATE+30);
CALL pr_generate_bill(6,CURRENT_DATE+30);

-- 7(e) Overdue unpaid bills
CREATE OR REPLACE VIEW v_overdue_bills AS
SELECT c.full_name,b.due_on,(b.charge-b.amount_paid) AS outstanding_amount
FROM bills b JOIN readings r ON r.reading_id=b.reading_id
JOIN customers c ON c.customer_id=r.customer_id
WHERE b.due_on<CURRENT_DATE AND b.amount_paid<b.charge;
SELECT * FROM v_overdue_bills;

-- 7(f) Date-based index for unpaid/partly paid bills
CREATE INDEX idx_bills_due_unpaid ON bills(due_on)
WHERE amount_paid<charge;
EXPLAIN SELECT * FROM bills
WHERE due_on<CURRENT_DATE AND amount_paid<charge;

-- 7(g) Today's receivable snapshot, idempotent on rerun
CREATE OR REPLACE PROCEDURE pr_refresh_receivables()
LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO receivable_snapshot(snapshot_date,total_due)
    SELECT CURRENT_DATE,COALESCE(SUM(charge-amount_paid),0)
    FROM bills WHERE amount_paid<charge
    ON CONFLICT(snapshot_date) DO UPDATE SET total_due=EXCLUDED.total_due;
END;
$$;

CREATE EXTENSION IF NOT EXISTS pg_cron;
SELECT cron.schedule('q7-refresh-receivables','30 0 * * *',
    $$CALL q7_water.pr_refresh_receivables()$$);

CALL pr_refresh_receivables();
SELECT * FROM readings;
SELECT * FROM bills;
SELECT * FROM receivable_snapshot;
