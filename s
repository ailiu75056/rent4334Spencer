CREATE OR REPLACE TABLE bug_summaries AS
WITH clean_comments AS (
  SELECT
    c.work_item_id,
    c.created_at,
    -- strip HTML from Azure DevOps comments and collapse whitespace
    TRIM(REGEXP_REPLACE(
      REGEXP_REPLACE(c.comment_text, '<[^>]+>', ' '),
      '\\s+', ' ')) AS clean_text,
    c.author
  FROM work_item_comments c
  WHERE c.is_deleted = FALSE
    AND c.author NOT IN ('Azure DevOps', 'Build Service')  -- drop bot accounts
),
eligible AS (
  SELECT work_item_id
  FROM clean_comments
  GROUP BY work_item_id
  HAVING COUNT(*) >= 10
),
thread AS (
  -- add the title and description as the first "entry" so the model has context
  SELECT w.work_item_id,
         '1900-01-01'::TIMESTAMP AS created_at,
         'WORK ITEM: ' || w.title || ' | DESCRIPTION: ' ||
           COALESCE(REGEXP_REPLACE(w.description, '<[^>]+>', ' '), '') AS entry
  FROM work_items w
  JOIN eligible e USING (work_item_id)
  UNION ALL
  SELECT c.work_item_id,
         c.created_at,
         '[' || TO_VARCHAR(c.created_at, 'YYYY-MM-DD HH24:MI') || '] '
           || c.author || ': ' || c.clean_text
  FROM clean_comments c
  JOIN eligible e USING (work_item_id)
)
SELECT
  work_item_id,
  AI_AGG(
    entry,
    'You are given the title, description, and comments of one Azure DevOps
     work item. Each comment starts with a timestamp in brackets; use the
     timestamps to reconstruct the order of events. Write a structured
     summary with these sections: Problem, Repro steps, Root cause (if found),
     Key decisions (with dates and who made them), Current state of the
     discussion, Open questions, Next steps. Note any disagreements.'
  ) AS summary,
  MAX(created_at) AS last_summarized_comment_at,
  COUNT(*) - 1    AS comment_count,
  CURRENT_TIMESTAMP() AS updated_at
FROM thread
GROUP BY work_item_id;