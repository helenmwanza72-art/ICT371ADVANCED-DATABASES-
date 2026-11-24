-- ICT371 - Question 2: University Fee Payments
CREATE SCHEMA IF NOT EXISTS q2_fees;
SET search_path TO q2_fees, public;

CREATE TABLE students (
    student_id SERIAL PRIMARY KEY,
    student_number VARCHAR(20) NOT NULL UNIQUE,
    full_name VARCHAR(100) NOT NULL,
    fee_due NUMERIC(12,2) NOT NULL CHECK (fee_due >= 0)
);
CREATE TABLE payments (
    payment_id SERIAL PRIMARY KEY,
    student_id INTEGER NOT NULL REFERENCES students(student_id),
    amount NUMERIC(12,2) NOT NULL CHECK (amount > 0),
    paid_on DATE NOT NULL
);
CREATE TABLE payment_audit (
    audit_id SERIAL PRIMARY KEY,
    payment_id INTEGER NOT NULL REFERENCES payments(payment_id),
    student_id INTEGER NOT NULL REFERENCES students(student_id),
    amount NUMERIC(12,2) NOT NULL,
    logged_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);
CREATE TABLE daily_collections (
    collection_date DATE PRIMARY KEY,
    payment_count INTEGER NOT NULL,
    total_amount NUMERIC(14,2) NOT NULL
);

INSERT INTO students(student_number, full_name, fee_due) VALUES
('ST001','Mary Banda',1000), ('ST002','Brian Phiri',800), ('ST003','Chipo Mwansa',500);

-- 2(b) Function
CREATE OR REPLACE FUNCTION fn_fee_balance(p_student_id INTEGER)
RETURNS NUMERIC(12,2) LANGUAGE plpgsql AS $$
DECLARE v_fee NUMERIC(12,2); v_paid NUMERIC(12,2);
BEGIN
    SELECT fee_due INTO v_fee FROM students WHERE student_id = p_student_id;
    IF NOT FOUND THEN RAISE EXCEPTION 'Unknown student ID: %', p_student_id; END IF;
    SELECT COALESCE(SUM(amount),0) INTO v_paid
    FROM payments WHERE student_id = p_student_id;
    RETURN v_fee - v_paid;
END;
$$;

-- 2(d) Audit trigger: the procedure deliberately does not insert audit rows
CREATE OR REPLACE FUNCTION fn_audit_payment_insert()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO payment_audit(payment_id, student_id, amount, logged_at)
    VALUES (NEW.payment_id, NEW.student_id, NEW.amount, CURRENT_TIMESTAMP);
    RETURN NEW;
END;
$$;
CREATE TRIGGER trg_payment_audit
AFTER INSERT ON payments
FOR EACH ROW EXECUTE FUNCTION fn_audit_payment_insert();

-- 2(c) Procedure
CREATE OR REPLACE PROCEDURE pr_receive_payment(
    p_student_id INTEGER, p_amount NUMERIC, p_paid_on DATE
)
LANGUAGE plpgsql AS $$
DECLARE v_balance NUMERIC(12,2);
BEGIN
    IF p_amount IS NULL OR p_amount <= 0 OR p_paid_on IS NULL THEN
        RAISE EXCEPTION 'Payment amount must be positive and payment date is required';
    END IF;
    PERFORM 1 FROM students WHERE student_id = p_student_id FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'Unknown student ID: %', p_student_id; END IF;
    v_balance := fn_fee_balance(p_student_id);
    IF p_amount > v_balance THEN RAISE EXCEPTION 'Payment exceeds outstanding balance'; END IF;
    INSERT INTO payments(student_id, amount, paid_on)
    VALUES (p_student_id, p_amount, p_paid_on);
END;
$$;

-- At least six valid payments; third student initially has no payments
CALL pr_receive_payment(1,100,CURRENT_DATE);
CALL pr_receive_payment(1,150,CURRENT_DATE);
CALL pr_receive_payment(1,200,CURRENT_DATE);
CALL pr_receive_payment(2,100,CURRENT_DATE);
CALL pr_receive_payment(2,200,CURRENT_DATE);
CALL pr_receive_payment(2,100,CURRENT_DATE);

-- 2(e) View
CREATE OR REPLACE VIEW v_fee_balances AS
SELECT s.student_number, s.full_name,
       s.fee_due - COALESCE(SUM(p.amount),0) AS outstanding_balance
FROM students s
LEFT JOIN payments p ON p.student_id = s.student_id
GROUP BY s.student_id, s.student_number, s.full_name, s.fee_due
HAVING s.fee_due - COALESCE(SUM(p.amount),0) > 0;
SELECT * FROM v_fee_balances;

-- 2(f) Index
CREATE INDEX idx_payments_student_paid_on ON payments(student_id, paid_on);
EXPLAIN SELECT * FROM payments
WHERE student_id = 1
  AND paid_on BETWEEN DATE '2026-01-01' AND DATE '2026-12-31';

-- 2(g) Daily summary, replacing rather than adding on reruns
CREATE OR REPLACE PROCEDURE pr_refresh_collections(p_day DATE)
LANGUAGE plpgsql AS $$
BEGIN
    IF p_day IS NULL THEN RAISE EXCEPTION 'Collection date is required'; END IF;
    INSERT INTO daily_collections(collection_date, payment_count, total_amount)
    SELECT p_day, COUNT(*), COALESCE(SUM(amount),0)
    FROM payments WHERE paid_on = p_day
    ON CONFLICT (collection_date) DO UPDATE
    SET payment_count = EXCLUDED.payment_count,
        total_amount = EXCLUDED.total_amount;
END;
$$;

-- Scheduling requires pg_cron to be installed and enabled by the PostgreSQL administrator.
CREATE EXTENSION IF NOT EXISTS pg_cron;
SELECT cron.schedule(
    'q2-refresh-fee-collections',
    '0 1 * * *',
    $$CALL q2_fees.pr_refresh_collections(CURRENT_DATE - 1)$$
);

-- Verification
CALL pr_refresh_collections(CURRENT_DATE);
SELECT * FROM students;
SELECT * FROM payments;
SELECT * FROM payment_audit;
SELECT * FROM v_fee_balances;
SELECT * FROM daily_collections;
