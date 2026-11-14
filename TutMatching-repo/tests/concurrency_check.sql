SELECT t_assert((SELECT count(*) FROM matches) = 30, '30 matches from 60 simultaneous requests');
SELECT t_assert((SELECT count(*) FROM submissions WHERE status = 'matched') = 60, 'all 60 students matched');
SELECT t_assert(NOT EXISTS (SELECT 1 FROM (SELECT s FROM (SELECT submission_a_id s FROM matches UNION ALL SELECT submission_b_id FROM matches) x GROUP BY s HAVING count(*) > 1) y), 'nobody is in two matches');
