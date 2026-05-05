//! OpenTelemetry GenAI Semantic Conventions
//!
//! Attribute names and known values for Generative AI instrumentation.
//! Spec: https://github.com/open-telemetry/semantic-conventions-genai (pegged to semconv v1.41.0)

// Core identity

pub const PROVIDER_NAME = "gen_ai.provider.name";
pub const OPERATION_NAME = "gen_ai.operation.name";

pub const ProviderName = struct {
    pub const openai = "openai";
    pub const anthropic = "anthropic";
    pub const @"aws.bedrock" = "aws.bedrock";
    pub const @"azure.ai.inference" = "azure.ai.inference";
    pub const @"azure.ai.openai" = "azure.ai.openai";
    pub const cohere = "cohere";
    pub const deepseek = "deepseek";
    pub const @"gcp.gen_ai" = "gcp.gen_ai";
    pub const @"gcp.gemini" = "gcp.gemini";
    pub const @"gcp.vertex_ai" = "gcp.vertex_ai";
    pub const groq = "groq";
    pub const @"ibm.watsonx.ai" = "ibm.watsonx.ai";
    pub const mistral_ai = "mistral_ai";
    pub const perplexity = "perplexity";
    pub const x_ai = "x_ai";
};

pub const OperationName = struct {
    pub const chat = "chat";
    pub const create_agent = "create_agent";
    pub const embeddings = "embeddings";
    pub const execute_tool = "execute_tool";
    pub const generate_content = "generate_content";
    pub const invoke_agent = "invoke_agent";
    pub const invoke_workflow = "invoke_workflow";
    pub const retrieval = "retrieval";
    pub const text_completion = "text_completion";
};

// Request parameters

pub const REQUEST_MODEL = "gen_ai.request.model";
pub const REQUEST_MAX_TOKENS = "gen_ai.request.max_tokens";
pub const REQUEST_CHOICE_COUNT = "gen_ai.request.choice.count";
pub const REQUEST_TEMPERATURE = "gen_ai.request.temperature";
pub const REQUEST_TOP_P = "gen_ai.request.top_p";
pub const REQUEST_TOP_K = "gen_ai.request.top_k";
pub const REQUEST_STOP_SEQUENCES = "gen_ai.request.stop_sequences";
pub const REQUEST_FREQUENCY_PENALTY = "gen_ai.request.frequency_penalty";
pub const REQUEST_PRESENCE_PENALTY = "gen_ai.request.presence_penalty";
pub const REQUEST_ENCODING_FORMATS = "gen_ai.request.encoding_formats";
pub const REQUEST_SEED = "gen_ai.request.seed";
pub const REQUEST_STREAM = "gen_ai.request.stream";

// Output type

pub const OUTPUT_TYPE = "gen_ai.output.type";

pub const OutputType = struct {
    pub const text = "text";
    pub const json = "json";
    pub const image = "image";
    pub const speech = "speech";
};

// Response

pub const RESPONSE_ID = "gen_ai.response.id";
pub const RESPONSE_MODEL = "gen_ai.response.model";
pub const RESPONSE_FINISH_REASONS = "gen_ai.response.finish_reasons";
pub const RESPONSE_TIME_TO_FIRST_CHUNK = "gen_ai.response.time_to_first_chunk";

// Token usage

pub const USAGE_INPUT_TOKENS = "gen_ai.usage.input_tokens";
pub const USAGE_OUTPUT_TOKENS = "gen_ai.usage.output_tokens";
pub const USAGE_CACHE_READ_INPUT_TOKENS = "gen_ai.usage.cache_read.input_tokens";
pub const USAGE_CACHE_CREATION_INPUT_TOKENS = "gen_ai.usage.cache_creation.input_tokens";
pub const USAGE_REASONING_OUTPUT_TOKENS = "gen_ai.usage.reasoning.output_tokens";

pub const TOKEN_TYPE = "gen_ai.token.type";

pub const TokenType = struct {
    pub const input = "input";
    pub const output = "output";
    // Note: "completion" member was deprecated and renamed to "output" — omitted.
};

// Conversation

pub const CONVERSATION_ID = "gen_ai.conversation.id";
pub const PROMPT_NAME = "gen_ai.prompt.name";

// Agent attributes

pub const AGENT_ID = "gen_ai.agent.id";
pub const AGENT_NAME = "gen_ai.agent.name";
pub const AGENT_DESCRIPTION = "gen_ai.agent.description";
pub const AGENT_VERSION = "gen_ai.agent.version";
pub const WORKFLOW_NAME = "gen_ai.workflow.name";

// Tool execution

pub const TOOL_NAME = "gen_ai.tool.name";
pub const TOOL_CALL_ID = "gen_ai.tool.call.id";
pub const TOOL_DESCRIPTION = "gen_ai.tool.description";
pub const TOOL_TYPE = "gen_ai.tool.type";
pub const TOOL_CALL_ARGUMENTS = "gen_ai.tool.call.arguments";
pub const TOOL_CALL_RESULT = "gen_ai.tool.call.result";
pub const TOOL_DEFINITIONS = "gen_ai.tool.definitions";

// Retrieval / RAG

pub const DATA_SOURCE_ID = "gen_ai.data_source.id";
pub const RETRIEVAL_DOCUMENTS = "gen_ai.retrieval.documents";
pub const RETRIEVAL_QUERY_TEXT = "gen_ai.retrieval.query.text";

// Embeddings

pub const EMBEDDINGS_DIMENSION_COUNT = "gen_ai.embeddings.dimension.count";

// Content (opt-in, sensitive)

pub const INPUT_MESSAGES = "gen_ai.input.messages";
pub const OUTPUT_MESSAGES = "gen_ai.output.messages";
pub const SYSTEM_INSTRUCTIONS = "gen_ai.system_instructions";

// Evaluation events

pub const EVALUATION_NAME = "gen_ai.evaluation.name";
pub const EVALUATION_SCORE_VALUE = "gen_ai.evaluation.score.value";
pub const EVALUATION_SCORE_LABEL = "gen_ai.evaluation.score.label";
pub const EVALUATION_EXPLANATION = "gen_ai.evaluation.explanation";

// Metrics — client-side

pub const CLIENT_TOKEN_USAGE = "gen_ai.client.token.usage";
pub const CLIENT_OPERATION_DURATION = "gen_ai.client.operation.duration";
pub const CLIENT_OPERATION_TIME_TO_FIRST_CHUNK = "gen_ai.client.operation.time_to_first_chunk";
pub const CLIENT_OPERATION_TIME_PER_OUTPUT_CHUNK = "gen_ai.client.operation.time_per_output_chunk";

// Metrics — server-side

pub const SERVER_REQUEST_DURATION = "gen_ai.server.request.duration";
pub const SERVER_TIME_PER_OUTPUT_TOKEN = "gen_ai.server.time_per_output_token";
pub const SERVER_TIME_TO_FIRST_TOKEN = "gen_ai.server.time_to_first_token";
