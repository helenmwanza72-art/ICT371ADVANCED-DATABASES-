-- ICT371 - Question 10: Scholarship Application Assessment
CREATE SCHEMA IF NOT EXISTS q10_scholarship;
SET search_path TO q10_scholarship, public;

CREATE TABLE students (
    student_id SERIAL PRIMARY KEY,
    student_number VARCHAR(20) NOT NULL UNIQUE,
    full_name VARCHAR(100) NOT NULL
);
CREATE TABLE applications (
    application_id SERIAL PRIMARY KEY,
    student_id INTEGER NOT NULL REFERENCES students(student_id),
    age_at_application INTEGER NOT NULL CHECK(age_at_application>0),
    monthly_income NUMERIC(12,2) NOT NULL CHECK(monthly_income>=0),
    average_mark NUMERIC(5,2) NOT NULL CHECK(average_mark BETWEEN 0 AND 100),
    submitted_on DATE NOT NULL,
    status VARCHAR(10) NOT NULL DEFAULT 'PENDING'
      CHECK(status IN ('PENDING','APPROVED','REJECTED'))
);
CREATE TABLE decision_audit (
    audit_id SERIAL PRIMARY KEY,
    application_id INTEGER NOT NULL REFERENCES applications(application_id),
    old_status VARCHAR(10) NOT NULL,
    new_status VARCHAR(10) NOT NULL,
    changed_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);

INSERT INTO students(student_number,full_name) VALUES
('ST201','Mary Banda'),('ST202','Brian Phiri'),('ST203','Chipo Mwansa');
-- Six pending applications: qualifying, non-qualifying and boundary cases
INSERT INTO applications(student_id,age_at_application,monthly_income,average_mark,submitted_on,status) VALUES
(1,18,3000,70,CURRENT_DATE,'PENDING'),
(1,25,2500,85,CURRENT_DATE,'PENDING'),
(2,17,2000,80,CURRENT_DATE,'PENDING'),
(2,22,3001,90,CURRENT_DATE,'PENDING'),
(3,23,2800,69.99,CURRENT_DATE,'PENDING'),
(3,26,1000,95,CURRENT_DATE,'PENDING');

-- 10(b) Eligibility function
CREATE OR REPLACE FUNCTION fn_scholarship_eligible(
    p_age INTEGER,p_income NUMERIC,p_mark NUMERIC
)
RETURNS BOOLEAN LANGUAGE plpgsql AS $$
BEGIN
    IF p_age IS NULL OR p_income IS NULL OR p_mark IS NULL THEN
        RAISE EXCEPTION 'Eligibility inputs cannot be NULL';
    END IF;
    IF p_age<=0 THEN RAISE EXCEPTION 'Age must be positive'; END IF;
    IF p_income<0 THEN RAISE EXCEPTION 'Income cannot be negative'; END IF;
    IF p_mark<0 OR p_mark>100 THEN RAISE EXCEPTION 'Average mark must be from 0 to 100'; END IF;
    RETURN p_age BETWEEN 18 AND 25 AND p_income<=3000 AND p_mark>=70;
END;
$$;

-- 10(d) Audit actual status changes only
CREATE OR REPLACE FUNCTION fn_audit_decision_change()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    IF OLD.status IS DISTINCT FROM NEW.status THEN
        INSERT INTO decision_audit(application_id,old_status,new_status,changed_at)
        VALUES(NEW.application_id,OLD.status,NEW.status,CURRENT_TIMESTAMP);
    END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER trg_decision_audit
AFTER UPDATE OF status ON applications
FOR EACH ROW EXECUTE FUNCTION fn_audit_decision_change();

-- 10(c) Assess one pending application
CREATE OR REPLACE PROCEDURE pr_assess_application(p_application_id INTEGER)
LANGUAGE plpgsql AS $$
DECLARE r RECORD; v_new_status VARCHAR(10);
BEGIN
    SELECT application_id,age_at_application,monthly_income,average_mark,status
    INTO r FROM applications WHERE application_id=p_application_id FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'Unknown application ID: %',p_application_id; END IF;
    IF r.status<>'PENDING' THEN RAISE EXCEPTION 'Application has already been assessed'; END IF;
    IF fn_scholarship_eligible(r.age_at_application,r.monthly_income,r.average_mark) THEN
        v_new_status := 'APPROVED';
    ELSE
        v_new_status := 'REJECTED';
    END IF;
    UPDATE applications SET status=v_new_status WHERE application_id=p_application_id;
END;
$$;

-- 10(e) Approved applicants only; household income is not exposed
CREATE OR REPLACE VIEW v_approved_applicants AS
SELECT s.student_number,s.full_name,a.average_mark,a.status
FROM applications a JOIN students s ON s.student_id=a.student_id
WHERE a.status='APPROVED';
SELECT * FROM v_approved_applicants;

-- 10(f) Status/date search index
CREATE INDEX idx_applications_status_submitted ON applications(status,submitted_on);
EXPLAIN SELECT * FROM applications
WHERE status='PENDING'
  AND submitted_on BETWEEN DATE '2026-01-01' AND DATE '2026-12-31';

-- 10(g) Process pending rows only; reruns do not reassess completed applications
CREATE OR REPLACE PROCEDURE pr_assess_pending()
LANGUAGE plpgsql AS $$
DECLARE r RECORD;
BEGIN
    FOR r IN SELECT application_id FROM applications
             WHERE status='PENDING' ORDER BY application_id
    LOOP
        CALL pr_assess_application(r.application_id);
    END LOOP;
END;
$$;

CREATE EXTENSION IF NOT EXISTS pg_cron;
SELECT cron.schedule('q10-assess-pending','0 8 * * 1',
    $$CALL q10_scholarship.pr_assess_pending()$$);

CALL pr_assess_pending();
SELECT * FROM applications;
SELECT * FROM decision_audit;
SELECT * FROM v_approved_applicants;
