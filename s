CREATE OR REPLACE TABLE bug_summaries_trial AS
WITH clean_comments AS (
  SELECT
    c.work_item_id,
    c.created_at,
    TRIM(REGEXP_REPLACE(
      REGEXP_REPLACE(c.comment_text, '<[^>]+>', ' '),
      '\\s+', ' ')) AS clean_text,
    c.author
  FROM work_item_comments c
  WHERE c.is_deleted = FALSE
    AND c.author NOT IN ('Azure DevOps', 'Build Service')
),
eligible AS (
  SELECT work_item_id
  FROM clean_comments
  GROUP BY work_item_id
  HAVING COUNT(*) >= 10
  ORDER BY COUNT(*) DESC
  LIMIT 10
),
threads AS (
  SELECT
    w.work_item_id,
    w.title,
    COALESCE(REGEXP_REPLACE(w.description, '<[^>]+>', ' '), '') AS description,
    LISTAGG(
      '[' || TO_VARCHAR(c.created_at, 'YYYY-MM-DD HH24:MI') || '] '
        || c.author || ': ' || c.clean_text,
      '\n'
    ) WITHIN GROUP (ORDER BY c.created_at) AS thread_text,
    COUNT(*)          AS comment_count,
    MAX(c.created_at) AS last_comment_at
  FROM work_items w
  JOIN eligible e        USING (work_item_id)
  JOIN clean_comments c  USING (work_item_id)
  GROUP BY w.work_item_id, w.title, w.description
),
sized AS (
  SELECT *,
         (LENGTH(thread_text) + LENGTH(description)) / 4 AS approx_tokens
  FROM threads
)
SELECT
  work_item_id,
  comment_count,
  approx_tokens,
  CASE WHEN approx_tokens <= 150000 THEN   -- set below your model's context limit
    AI_COMPLETE(
      model => 'claude-sonnet-4-5',        -- swap for any model available in your region
      prompt =>
        'You are summarizing one Azure DevOps work item for subject-matter experts. '
        || 'Comments are in chronological order. Write a structured summary with these '
        || 'sections: Problem, Repro steps, Root cause (if found), Key decisions (with '
        || 'dates and who made them), Current state of the discussion, Open questions, '
        || 'Next steps. Note any disagreements. Only use information in the thread.'
        || '\n\n<work_item>\nTitle: ' || title
        || '\nDescription: ' || description
        || '\n</work_item>\n\n<comments>\n' || thread_text || '\n</comments>',
      model_parameters => {'temperature': 0, 'max_tokens': 2000}
    )
  END AS summary,
  CASE WHEN approx_tokens > 150000 THEN 'TOO_LARGE' ELSE 'OK' END AS status,
  last_comment_at AS last_summarized_comment_at,
  CURRENT_TIMESTAMP() AS updated_at
FROM sized;