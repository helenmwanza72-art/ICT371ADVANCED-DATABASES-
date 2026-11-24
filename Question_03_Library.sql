-- ICT371 - Question 3: Library Returns and Overdue Fines
CREATE SCHEMA IF NOT EXISTS q3_library;
SET search_path TO q3_library, public;

CREATE TABLE books (
    book_id SERIAL PRIMARY KEY,
    title VARCHAR(150) NOT NULL
);
CREATE TABLE loans (
    loan_id SERIAL PRIMARY KEY,
    book_id INTEGER NOT NULL REFERENCES books(book_id),
    borrower_name VARCHAR(100) NOT NULL,
    borrowed_on DATE NOT NULL,
    due_on DATE NOT NULL,
    returned_on DATE,
    fine_amount NUMERIC(12,2) NOT NULL DEFAULT 0 CHECK (fine_amount >= 0),
    CHECK (due_on >= borrowed_on),
    CHECK (returned_on IS NULL OR returned_on >= borrowed_on)
);
CREATE TABLE loan_audit (
    audit_id SERIAL PRIMARY KEY,
    loan_id INTEGER NOT NULL REFERENCES loans(loan_id),
    old_returned_on DATE,
    new_returned_on DATE,
    changed_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);
CREATE TABLE overdue_summary (
    snapshot_date DATE PRIMARY KEY,
    overdue_count INTEGER NOT NULL,
    total_fine NUMERIC(14,2) NOT NULL
);

INSERT INTO books(title) VALUES
('Database Systems'),('Computer Networks'),('Programming in Java');

-- Six loans: open overdue, on-time, and returned late examples
INSERT INTO loans(book_id, borrower_name, borrowed_on, due_on, returned_on, fine_amount) VALUES
(1,'Mary Banda',CURRENT_DATE-20,CURRENT_DATE-10,NULL,0),
(2,'Brian Phiri',CURRENT_DATE-12,CURRENT_DATE-5,CURRENT_DATE-5,0),
(3,'Chipo Mwansa',CURRENT_DATE-20,CURRENT_DATE-12,CURRENT_DATE-8,8),
(1,'David Tembo',CURRENT_DATE-15,CURRENT_DATE-7,NULL,0),
(2,'Esther Zulu',CURRENT_DATE-10,CURRENT_DATE+5,NULL,0),
(3,'Felix Musonda',CURRENT_DATE-8,CURRENT_DATE+2,NULL,0);

-- 3(b) Fine function: K2 per day after due date, capped at return date
CREATE OR REPLACE FUNCTION fn_loan_fine(p_loan_id INTEGER, p_as_of DATE)
RETURNS NUMERIC(12,2) LANGUAGE plpgsql AS $$
DECLARE v_due DATE; v_returned DATE; v_end DATE;
BEGIN
    IF p_as_of IS NULL THEN RAISE EXCEPTION 'As-of date is required'; END IF;
    SELECT due_on, returned_on INTO v_due, v_returned
    FROM loans WHERE loan_id = p_loan_id;
    IF NOT FOUND THEN RAISE EXCEPTION 'Unknown loan ID: %', p_loan_id; END IF;
    v_end := LEAST(p_as_of, COALESCE(v_returned, p_as_of));
    RETURN GREATEST(v_end - v_due, 0) * 2.00;
END;
$$;

-- 3(d) Audit trigger
CREATE OR REPLACE FUNCTION fn_audit_loan_return()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    IF OLD.returned_on IS DISTINCT FROM NEW.returned_on THEN
        INSERT INTO loan_audit(loan_id, old_returned_on, new_returned_on)
        VALUES (NEW.loan_id, OLD.returned_on, NEW.returned_on);
    END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER trg_loan_return_audit
AFTER UPDATE OF returned_on ON loans
FOR EACH ROW EXECUTE FUNCTION fn_audit_loan_return();

-- 3(c) Return procedure
CREATE OR REPLACE PROCEDURE pr_return_loan(p_loan_id INTEGER, p_returned_on DATE)
LANGUAGE plpgsql AS $$
DECLARE v_borrowed DATE; v_returned DATE; v_fine NUMERIC(12,2);
BEGIN
    IF p_returned_on IS NULL THEN RAISE EXCEPTION 'Return date is required'; END IF;
    SELECT borrowed_on, returned_on INTO v_borrowed, v_returned
    FROM loans WHERE loan_id = p_loan_id FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'Unknown loan ID: %', p_loan_id; END IF;
    IF v_returned IS NOT NULL THEN RAISE EXCEPTION 'Loan has already been returned'; END IF;
    IF p_returned_on < v_borrowed THEN RAISE EXCEPTION 'Return date precedes borrowed date'; END IF;
    v_fine := GREATEST(p_returned_on - (SELECT due_on FROM loans WHERE loan_id=p_loan_id),0) * 2.00;
    UPDATE loans SET returned_on = p_returned_on, fine_amount = v_fine
    WHERE loan_id = p_loan_id;
END;
$$;

-- 3(e) View
CREATE OR REPLACE VIEW v_overdue_loans AS
SELECT b.title, l.borrower_name, l.due_on,
       fn_loan_fine(l.loan_id, CURRENT_DATE) AS fine_as_of_today
FROM loans l JOIN books b ON b.book_id = l.book_id
WHERE l.returned_on IS NULL AND l.due_on < CURRENT_DATE;
SELECT * FROM v_overdue_loans;

-- 3(f) Partial index for unreturned loans of a particular book
CREATE INDEX idx_loans_open_by_book ON loans(book_id)
WHERE returned_on IS NULL;
EXPLAIN SELECT * FROM loans WHERE book_id = 1 AND returned_on IS NULL;

-- 3(g) Snapshot counts loans still unreturned on the specified date
CREATE OR REPLACE PROCEDURE pr_refresh_overdue(p_as_of DATE)
LANGUAGE plpgsql AS $$
BEGIN
    IF p_as_of IS NULL THEN RAISE EXCEPTION 'Snapshot date is required'; END IF;
    INSERT INTO overdue_summary(snapshot_date, overdue_count, total_fine)
    SELECT p_as_of, COUNT(*),
           COALESCE(SUM(GREATEST(p_as_of - due_on,0) * 2.00),0)
    FROM loans
    WHERE returned_on IS NULL AND due_on < p_as_of
    ON CONFLICT (snapshot_date) DO UPDATE
    SET overdue_count = EXCLUDED.overdue_count,
        total_fine = EXCLUDED.total_fine;
END;
$$;

-- Scheduling requires pg_cron to be installed and enabled by the PostgreSQL administrator.
CREATE EXTENSION IF NOT EXISTS pg_cron;
SELECT cron.schedule(
    'q3-refresh-overdue',
    '10 0 * * *',
    $$CALL q3_library.pr_refresh_overdue(CURRENT_DATE)$$
);

CALL pr_refresh_overdue(CURRENT_DATE);
SELECT * FROM loans;
SELECT * FROM loan_audit;
SELECT * FROM overdue_summary;
