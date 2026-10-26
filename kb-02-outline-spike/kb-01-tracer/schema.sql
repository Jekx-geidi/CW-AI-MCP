CREATE EXTENSION IF NOT EXISTS vector;

CREATE TABLE knowledge_document (
    id              TEXT PRIMARY KEY,          -- Outline document id
    url_id          TEXT NOT NULL,
    title           TEXT NOT NULL,
    text            TEXT NOT NULL,              -- exported Markdown
    frontmatter     JSONB NOT NULL,             -- hand-populated metadata row
    search_vector   TSVECTOR,
    embedding       VECTOR(8),                  -- placeholder dim; real model TBD in KB-06
    client          TEXT NOT NULL,              -- single-client scope for the tracer
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX knowledge_document_search_idx ON knowledge_document USING GIN (search_vector);
CREATE INDEX knowledge_document_embedding_idx ON knowledge_document USING ivfflat (embedding vector_cosine_ops) WITH (lists = 1);

CREATE FUNCTION knowledge_document_search_vector_trigger() RETURNS trigger AS $$
BEGIN
    NEW.search_vector := to_tsvector('english', coalesce(NEW.title, '') || ' ' || coalesce(NEW.text, ''));
    RETURN NEW;
END
$$ LANGUAGE plpgsql;

CREATE TRIGGER knowledge_document_search_vector_update
    BEFORE INSERT OR UPDATE ON knowledge_document
    FOR EACH ROW EXECUTE FUNCTION knowledge_document_search_vector_trigger();
