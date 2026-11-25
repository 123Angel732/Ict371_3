-- QUESTION 3: LIBRARY RETURNS AND OVERDUE FINES
CREATE TABLE books (
book_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
title TEXT NOT NULL
);
CREATE TABLE loans (
loan_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
book_id BIGINT NOT NULL REFERENCES books(book_id),
borrower_name TEXT NOT NULL,
borrowed_on DATE NOT NULL,
due_on DATE NOT NULL,
returned_on DATE,
fine_amount NUMERIC(10,2) NOT NULL DEFAULT 0 CHECK (fine_amount >= 0),
ICT371 Advanced Database – Worked Solutions Page 5
CHECK (due_on >= borrowed_on),
CHECK (returned_on IS NULL OR returned_on >= borrowed_on)
);
CREATE TABLE loan_audit (
audit_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
loan_id BIGINT NOT NULL REFERENCES loans(loan_id),
old_returned_on DATE,
new_returned_on DATE,
changed_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);
CREATE TABLE overdue_summary (
snapshot_date DATE PRIMARY KEY,
overdue_count BIGINT NOT NULL,
total_fine NUMERIC(14,2) NOT NULL
);

--b

CREATE OR REPLACE FUNCTION fn_loan_fine(p_loan_id BIGINT, p_as_of DATE)
RETURNS NUMERIC(10,2) LANGUAGE plpgsql AS $$
DECLARE v_due DATE; v_returned DATE; v_end DATE; v_days INTEGER;
BEGIN
SELECT due_on, returned_on INTO v_due, v_returned
FROM loans WHERE loan_id = p_loan_id;
IF NOT FOUND THEN RAISE EXCEPTION 'Unknown loan ID %', p_loan_id; END IF;
IF p_as_of IS NULL THEN RAISE EXCEPTION 'As-of date is required'; END IF;
v_end := LEAST(p_as_of, COALESCE(v_returned, p_as_of));
v_days := GREATEST(v_end - v_due, 0);
RETURN v_days * 2.00;
END; $$;

--c

CREATE OR REPLACE PROCEDURE pr_return_loan(p_loan_id BIGINT, p_returned_on DATE)
LANGUAGE plpgsql AS $$
DECLARE v_borrowed DATE; v_due DATE; v_returned DATE; v_fine NUMERIC(10,2);
BEGIN
IF p_returned_on IS NULL THEN RAISE EXCEPTION 'Return date is required'; END IF;
SELECT borrowed_on, due_on, returned_on INTO v_borrowed, v_due, v_returned
FROM loans WHERE loan_id = p_loan_id FOR UPDATE;
IF NOT FOUND THEN RAISE EXCEPTION 'Unknown loan ID %', p_loan_id; END IF;
IF v_returned IS NOT NULL THEN RAISE EXCEPTION 'Loan % has already been returned', p_loan_id; END IF;
IF p_returned_on < v_borrowed THEN RAISE EXCEPTION 'Return date cannot precede borrowing date'; END IF;
v_fine := GREATEST(p_returned_on - v_due, 0) * 2.00;
UPDATE loans SET returned_on = p_returned_on, fine_amount = v_fine
WHERE loan_id = p_loan_id;
END; $$;

--d

CREATE OR REPLACE FUNCTION trg_loan_return_audit()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
IF OLD.returned_on IS DISTINCT FROM NEW.returned_on THEN
INSERT INTO loan_audit(loan_id, old_returned_on, new_returned_on)
VALUES (NEW.loan_id, OLD.returned_on, NEW.returned_on);
END IF;
RETURN NEW;
END; $$;
CREATE TRIGGER loans_return_audit
AFTER UPDATE ON loans FOR EACH ROW EXECUTE FUNCTION trg_loan_return_audit();

--e
CREATE OR REPLACE VIEW v_overdue_loans AS
SELECT l.loan_id, b.title, l.borrower_name, l.due_on,
fn_loan_fine(l.loan_id, CURRENT_DATE) AS fine_as_of_today
FROM loans l JOIN books b ON b.book_id = l.book_id
WHERE l.returned_on IS NULL AND l.due_on < CURRENT_DATE;

--f
CREATE INDEX idx_loans_open_by_book ON loans(book_id, due_on)
WHERE returned_on IS NULL;
EXPLAIN SELECT loan_id, borrower_name, due_on FROM loans
WHERE book_id = 1 AND returned_on IS NULL;

--g
CREATE OR REPLACE PROCEDURE pr_refresh_overdue(p_as_of DATE)
LANGUAGE plpgsql AS $$
BEGIN
IF p_as_of IS NULL THEN RAISE EXCEPTION 'Snapshot date is required'; END IF;
INSERT INTO overdue_summary(snapshot_date, overdue_count, total_fine)
SELECT p_as_of, COUNT(*), COALESCE(SUM(fn_loan_fine(loan_id, p_as_of)), 0)
FROM loans
-- still unreturned as of p_as_of (also correct for a past date)
WHERE (returned_on IS NULL OR returned_on > p_as_of) AND due_on < p_as_of
ON CONFLICT (snapshot_date) DO UPDATE
SET overdue_count = EXCLUDED.overdue_count, total_fine = EXCLUDED.total_fine;
END; $$;
-- Schedule: every day at 00:10 for CURRENT_DATE.
CREATE EXTENSION IF NOT EXISTS pg_cron;
SELECT cron.schedule('library-overdue-snapshot', '10 0 * * *',
$$CALL pr_refresh_overdue(CURRENT_DATE)$$);


--seeds
INSERT INTO books(title) VALUES ('Database Systems'), ('Networking Basics'), ('Clean Code');
INSERT INTO loans(book_id, borrower_name, borrowed_on, due_on, returned_on) VALUES
(1, 'Amina', DATE '2026-11-01', DATE '2026-11-10', NULL), -- open, overdue
(2, 'Brian', DATE '2026-11-01', DATE '2026-11-25', NULL), -- returned on time below
(3, 'Chanda', DATE '2026-11-01', DATE '2026-11-05', DATE '2026-11-05'), -- returned on due date
(1, 'David', DATE '2026-11-03', DATE '2026-11-12', NULL), -- open, overdue
(2, 'Eunice', DATE '2026-11-04', DATE '2026-11-14', NULL), -- returned late below
(3, 'Felix', DATE '2026-11-05', DATE '2026-11-20', NULL); -- open, overdue
CALL pr_return_loan(2, DATE '2026-11-24'); -- on time: fine 0.00
CALL pr_return_loan(5, DATE '2026-11-18'); -- 4 days late: fine 8.00
SELECT loan_id, borrower_name, returned_on, fine_amount FROM loans ORDER BY loan_id;
SELECT * FROM loan_audit ORDER BY audit_id; -- only the two real return-date changes
SELECT * FROM v_overdue_loans ORDER BY loan_id;
CALL pr_refresh_overdue(CURRENT_DATE);
CALL pr_refresh_overdue(CURRENT_DATE); -- rerun replaces the same snapshot_date
SELECT * FROM overdue_summary;