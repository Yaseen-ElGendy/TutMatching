-- What an older TutMatching database looked like before v5 (public policies, match_contacts, extra columns)
CREATE TABLE submissions (id UUID PRIMARY KEY DEFAULT gen_random_uuid(), student_id TEXT NOT NULL, email TEXT NOT NULL, major TEXT NOT NULL, current_tut TEXT NOT NULL, desired_tut TEXT NOT NULL, german_level TEXT, english_level TEXT, status TEXT DEFAULT 'waiting' CHECK (status IN ('waiting','matched')), created_at TIMESTAMP DEFAULT NOW(), matched_at TIMESTAMP, UNIQUE(student_id));
CREATE TABLE matches (id UUID PRIMARY KEY DEFAULT gen_random_uuid(), submission_a_id UUID NOT NULL REFERENCES submissions(id), submission_b_id UUID NOT NULL REFERENCES submissions(id), coordinator_needed BOOLEAN DEFAULT FALSE, created_at TIMESTAMP DEFAULT NOW());
CREATE TABLE match_contacts (id UUID PRIMARY KEY DEFAULT gen_random_uuid(), match_id UUID NOT NULL UNIQUE REFERENCES matches(id) ON DELETE CASCADE, student_a_id TEXT NOT NULL, student_a_email TEXT NOT NULL, student_b_id TEXT NOT NULL, student_b_email TEXT NOT NULL, created_at TIMESTAMP DEFAULT NOW());
ALTER TABLE submissions ADD COLUMN user_id UUID; ALTER TABLE submissions ADD COLUMN phone TEXT;
ALTER TABLE submissions ENABLE ROW LEVEL SECURITY; ALTER TABLE matches ENABLE ROW LEVEL SECURITY; ALTER TABLE match_contacts ENABLE ROW LEVEL SECURITY;
CREATE POLICY p1 ON submissions FOR SELECT USING (true);
CREATE POLICY p2 ON submissions FOR INSERT WITH CHECK (true);
CREATE POLICY p3 ON submissions FOR UPDATE USING (true);
CREATE POLICY p4 ON matches FOR SELECT USING (true);
CREATE POLICY p5 ON match_contacts FOR SELECT USING (true);
