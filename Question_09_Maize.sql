-- ICT371 - Question 9: Farmer Cooperative Maize Deliveries
CREATE SCHEMA IF NOT EXISTS q9_maize;
SET search_path TO q9_maize, public;

CREATE TABLE farmers (
    farmer_id SERIAL PRIMARY KEY,
    farmer_number VARCHAR(20) NOT NULL UNIQUE,
    full_name VARCHAR(100) NOT NULL
);
CREATE TABLE deliveries (
    delivery_id SERIAL PRIMARY KEY,
    farmer_id INTEGER NOT NULL REFERENCES farmers(farmer_id),
    grade CHAR(1) NOT NULL CHECK(grade IN ('A','B','C')),
    weight_kg NUMERIC(12,2) NOT NULL CHECK(weight_kg>0),
    unit_rate NUMERIC(10,2) NOT NULL CHECK(unit_rate>0),
    total_value NUMERIC(14,2) NOT NULL CHECK(total_value>0),
    delivered_on DATE NOT NULL,
    is_paid BOOLEAN NOT NULL DEFAULT FALSE
);
CREATE TABLE daily_purchases (
    purchase_date DATE PRIMARY KEY,
    total_weight NUMERIC(14,2) NOT NULL,
    total_value NUMERIC(14,2) NOT NULL
);

INSERT INTO farmers(farmer_number,full_name) VALUES
('F001','Mary Banda'),('F002','Brian Phiri'),('F003','Chipo Mwansa');

-- 9(b) Grade rate function
CREATE OR REPLACE FUNCTION fn_maize_rate(p_grade CHAR(1))
RETURNS NUMERIC(10,2) LANGUAGE plpgsql AS $$
BEGIN
    IF p_grade IS NULL THEN RAISE EXCEPTION 'Grade cannot be NULL'; END IF;
    CASE UPPER(p_grade)
      WHEN 'A' THEN RETURN 5.00;
      WHEN 'B' THEN RETURN 4.00;
      WHEN 'C' THEN RETURN 3.00;
      ELSE RAISE EXCEPTION 'Unsupported maize grade: %',p_grade;
    END CASE;
END;
$$;

-- 9(d) Trigger calculates rate/value for both procedure and direct SQL inserts/updates
CREATE OR REPLACE FUNCTION fn_price_maize_delivery()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.weight_kg IS NULL OR NEW.weight_kg<=0 THEN
        RAISE EXCEPTION 'Delivery weight must be positive';
    END IF;
    NEW.unit_rate := fn_maize_rate(NEW.grade);
    NEW.total_value := NEW.weight_kg*NEW.unit_rate;
    RETURN NEW;
END;
$$;
CREATE TRIGGER trg_price_delivery
BEFORE INSERT OR UPDATE ON deliveries
FOR EACH ROW EXECUTE FUNCTION fn_price_maize_delivery();

-- 9(c) Procedure leaves calculated columns to the trigger
CREATE OR REPLACE PROCEDURE pr_receive_delivery(
    p_farmer_id INTEGER,p_grade CHAR(1),p_weight NUMERIC,p_date DATE
)
LANGUAGE plpgsql AS $$
BEGIN
    IF NOT EXISTS(SELECT 1 FROM farmers WHERE farmer_id=p_farmer_id) THEN
        RAISE EXCEPTION 'Unknown farmer ID';
    END IF;
    IF p_grade IS NULL OR p_weight IS NULL OR p_weight<=0 OR p_date IS NULL THEN
        RAISE EXCEPTION 'Invalid delivery details';
    END IF;
    PERFORM fn_maize_rate(p_grade);
    INSERT INTO deliveries(farmer_id,grade,weight_kg,unit_rate,total_value,delivered_on,is_paid)
    VALUES(p_farmer_id,UPPER(p_grade),p_weight,1,1,p_date,FALSE);
END;
$$;

-- Six deliveries covering all grades and both payment states
CALL pr_receive_delivery(1,'A',100,CURRENT_DATE);
CALL pr_receive_delivery(1,'B',80,CURRENT_DATE);
CALL pr_receive_delivery(2,'C',120,CURRENT_DATE);
CALL pr_receive_delivery(2,'A',60,CURRENT_DATE);
CALL pr_receive_delivery(3,'B',90,CURRENT_DATE);
CALL pr_receive_delivery(3,'C',70,CURRENT_DATE);
UPDATE deliveries SET is_paid=TRUE WHERE delivery_id IN (2,4,6);

-- 9(e) Include farmers with zero unpaid deliveries
CREATE OR REPLACE VIEW v_farmer_amount_due AS
SELECT f.farmer_number,f.full_name,
       COALESCE(SUM(d.total_value) FILTER(WHERE d.is_paid=FALSE),0) AS total_unpaid_value
FROM farmers f LEFT JOIN deliveries d ON d.farmer_id=f.farmer_id
GROUP BY f.farmer_id,f.farmer_number,f.full_name;
SELECT * FROM v_farmer_amount_due;

-- 9(f) Composite date-range index
CREATE INDEX idx_deliveries_farmer_date ON deliveries(farmer_id,delivered_on);
EXPLAIN SELECT * FROM deliveries
WHERE farmer_id=1 AND delivered_on BETWEEN DATE '2026-01-01' AND DATE '2026-12-31';

-- 9(g) Daily purchase totals, replace on rerun
CREATE OR REPLACE PROCEDURE pr_refresh_purchases(p_day DATE)
LANGUAGE plpgsql AS $$
BEGIN
    IF p_day IS NULL THEN RAISE EXCEPTION 'Purchase date is required'; END IF;
    INSERT INTO daily_purchases(purchase_date,total_weight,total_value)
    SELECT p_day,COALESCE(SUM(weight_kg),0),COALESCE(SUM(total_value),0)
    FROM deliveries WHERE delivered_on=p_day
    ON CONFLICT(purchase_date) DO UPDATE SET
      total_weight=EXCLUDED.total_weight,total_value=EXCLUDED.total_value;
END;
$$;

CREATE EXTENSION IF NOT EXISTS pg_cron;
SELECT cron.schedule('q9-refresh-daily-purchases','30 1 * * *',
    $$CALL q9_maize.pr_refresh_purchases(CURRENT_DATE - 1)$$);

CALL pr_refresh_purchases(CURRENT_DATE);
SELECT * FROM deliveries;
SELECT * FROM v_farmer_amount_due;
SELECT * FROM daily_purchases;
