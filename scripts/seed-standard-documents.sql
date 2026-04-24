-- Seed standard system documents for a new client.
-- Sets is_system = true so documents cannot be deleted by client_admins
-- and the flag cannot be unset (enforced by DB trigger).
--
-- IRP / ISP / DPP are client-specific: url is left null so the client admin
-- can upload their own PDFs via the org UI.
--
-- CHH is RAYN-provided: pass the storage URL via the psql variable :handbook_url
-- e.g.  psql $CONNECTION_STRING --variable="handbook_url=https://..." --file seed-standard-documents.sql
-- If :handbook_url is empty the row is still inserted with url = null.
--
-- Safe to re-run (idempotent via WHERE NOT EXISTS on lower-cased title).

INSERT INTO public.documents
  (title, category, description, required, is_system, url, file_name, file_type, version)
SELECT
  v.title,
  v.category,
  v.description,
  true,
  true,
  NULLIF(v.url, ''),
  v.file_name,
  v.file_type,
  1
FROM (VALUES
  (
    'Incident Response Plan',
    'policy',
    'Client incident response procedure. Upload your organisation''s PDF via the Documents section.',
    NULL::text,
    'incident-response-plan.pdf',
    'application/pdf'
  ),
  (
    'Incident Security Policy',
    'policy',
    'Client information security policy. Upload your organisation''s PDF via the Documents section.',
    NULL::text,
    'incident-security-policy.pdf',
    'application/pdf'
  ),
  (
    'Data Protection Policy',
    'policy',
    'Client data protection policy. Upload your organisation''s PDF via the Documents section.',
    NULL::text,
    'data-protection-policy.pdf',
    'application/pdf'
  ),
  (
    'Cybersecurity Handbook - All Staff',
    'handbook',
    'Core cybersecurity guidance for all staff, provided by RAYN Secure.',
    :'handbook_url',
    'cybersecurity-handbook-all-staff.pdf',
    'application/pdf'
  )
) AS v(title, category, description, url, file_name, file_type)
WHERE NOT EXISTS (
  SELECT 1 FROM public.documents d
  WHERE LOWER(d.title) = LOWER(v.title)
);
