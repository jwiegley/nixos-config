from dotenv import load_dotenv
load_dotenv()

from functools import wraps
from flask import Flask, jsonify, Response, request, render_template
import flask
import os
from cache import MemoryCache

app = Flask(__name__, static_url_path='')

# SETUP
cache = MemoryCache()

# Use local OpenAI-compatible API (LiteLLM) instead of Vanna cloud
# Using FAISS vector store (simpler, no compatibility issues)
from vanna.faiss import FAISS
from vanna.openai import OpenAI_Chat
from openai import OpenAI

class MyVanna(FAISS, OpenAI_Chat):
    def __init__(self, config=None):
        # Initialize FAISS vector store
        faiss_config = {
            'path': config.get('faiss_path', '/vanna/faiss'),
            'embedding_dim': 384,
            'embedding_model': 'all-MiniLM-L6-v2'
        }
        FAISS.__init__(self, config=faiss_config)

        # Create custom OpenAI client pointing to local LiteLLM
        self.client = OpenAI(
            api_key=config.get('api_key', 'dummy'),
            base_url=config.get('api_base', 'http://10.88.0.1:4000/v1')
        )

        # Initialize OpenAI Chat with model config
        openai_config = {
            'model': config.get('model', 'hera/gpt-oss-120b'),
            'allow_llm_to_see_data': True
        }
        OpenAI_Chat.__init__(self, config=openai_config)

# Configure Vanna with local OpenAI-compatible API
vn = MyVanna(config={
    'api_key': os.environ.get('OPENAI_API_KEY', ''),
    'api_base': os.environ.get('OPENAI_API_BASE', 'http://10.88.0.1:4000/v1'),
    'model': os.environ.get('VANNA_MODEL', 'hera/gpt-oss-120b'),
    'faiss_path': '/vanna/faiss'
})

# Database connection via environment variables
# Set these in your SOPS secrets (vanna-env):
#   MSSQL_HOST, MSSQL_DATABASE, MSSQL_USER, MSSQL_PASSWORD, MSSQL_PORT (optional)
#   POSTGRES_HOST, POSTGRES_DATABASE, POSTGRES_USER, POSTGRES_PASSWORD, POSTGRES_PORT (optional)

# Connect to MS SQL Server if credentials are provided
if all([os.environ.get('MSSQL_HOST'), os.environ.get('MSSQL_DATABASE'),
        os.environ.get('MSSQL_USER'), os.environ.get('MSSQL_PASSWORD')]):
    try:
        mssql_host = os.environ.get('MSSQL_HOST')
        mssql_database = os.environ.get('MSSQL_DATABASE')
        mssql_user = os.environ.get('MSSQL_USER')
        mssql_password = os.environ.get('MSSQL_PASSWORD')
        mssql_port = os.environ.get('MSSQL_PORT', '1433')

        # Build ODBC connection string for FreeTDS
        odbc_conn_str = (
            f"DRIVER={{FreeTDS}};"
            f"SERVER={mssql_host};"
            f"PORT={mssql_port};"
            f"DATABASE={mssql_database};"
            f"UID={mssql_user};"
            f"PWD={mssql_password};"
            f"TDS_Version=7.4;"
        )

        vn.connect_to_mssql(odbc_conn_str=odbc_conn_str)
        print(f"✓ Connected to MS SQL Server: {mssql_host}/{mssql_database}")
    except Exception as e:
        print(f"✗ Failed to connect to MS SQL Server: {e}")

# Connect to PostgreSQL if credentials are provided
elif all([os.environ.get('POSTGRES_HOST'), os.environ.get('POSTGRES_DATABASE'),
          os.environ.get('POSTGRES_USER'), os.environ.get('POSTGRES_PASSWORD')]):
    try:
        postgres_port = os.environ.get('POSTGRES_PORT', '5432')
        vn.connect_to_postgres(
            host=os.environ.get('POSTGRES_HOST'),
            dbname=os.environ.get('POSTGRES_DATABASE'),
            user=os.environ.get('POSTGRES_USER'),
            password=os.environ.get('POSTGRES_PASSWORD'),
            port=int(postgres_port)
        )
        print(f"✓ Connected to PostgreSQL: {os.environ.get('POSTGRES_HOST')}/{os.environ.get('POSTGRES_DATABASE')}")
    except Exception as e:
        print(f"✗ Failed to connect to PostgreSQL: {e}")
else:
    print("⚠ No database connection configured. Set MSSQL_* or POSTGRES_* environment variables.")

# NO NEED TO CHANGE ANYTHING BELOW THIS LINE
def requires_cache(fields):
    def decorator(f):
        @wraps(f)
        def decorated(*args, **kwargs):
            id = request.args.get('id')

            if id is None:
                return jsonify({"type": "error", "error": "No id provided"})

            for field in fields:
                if cache.get(id=id, field=field) is None:
                    return jsonify({"type": "error", "error": f"No {field} found"})

            field_values = {field: cache.get(id=id, field=field) for field in fields}

            return f(*args, **field_values, **kwargs)
        return decorated
    return decorator

# ROUTES
@app.route('/api/v0/generate_questions', methods=['GET'])
def generate_questions():
    try:
        questions = vn.generate_questions()
        return jsonify({"type": "question_list", "questions": questions, "header": "Here are some questions you can ask:"})
    except Exception as e:
        return jsonify({"type": "error", "error": str(e)})

@app.route('/api/v0/generate_sql', methods=['GET'])
def generate_sql():
    question = request.args.get('question')

    if question is None:
        return jsonify({"type": "error", "error": "No question provided"})

    id = cache.generate_id(question=question)
    sql = vn.generate_sql(question=question, allow_llm_to_see_data=True)

    cache.set(id=id, field='question', value=question)
    cache.set(id=id, field='sql', value=sql)

    return jsonify(
        {
            "type": "sql",
            "id": id,
            "text": sql,
        })

@app.route('/api/v0/run_sql', methods=['GET'])
@requires_cache(['sql'])
def run_sql(sql):
    id = request.args.get('id')

    try:
        df = vn.run_sql(sql=sql)
        cache.set(id=id, field='df', value=df)

        return jsonify(
            {
                "type": "df",
                "id": id,
                "df": df.head(10).to_json(orient='records'),
            })
    except Exception as e:
        return jsonify({"type": "error", "error": str(e)})

@app.route('/api/v0/download_csv', methods=['GET'])
@requires_cache(['df'])
def download_csv(df):
    csv = df.to_csv()

    return Response(
        csv,
        mimetype="text/csv",
        headers={"Content-disposition":
                 f"attachment; filename=vanna_results.csv"})

@app.route('/api/v0/generate_plotly_figure', methods=['GET'])
@requires_cache(['df', 'question', 'sql'])
def generate_plotly_figure(df, question, sql):
    id = request.args.get('id')
    chart_instructions = request.args.get('chart_instructions')

    try:
        code = vn.generate_plotly_code(question=question, sql=sql, df=df, chart_instructions=chart_instructions)
        fig = vn.get_plotly_figure(plotly_code=code, df=df)
        fig_html = fig.to_html()

        cache.set(id=id, field='fig_html', value=fig_html)

        return jsonify(
            {
                "type": "plotly_figure",
                "id": id,
                "fig": fig.to_json(),
            })
    except Exception as e:
        return jsonify({"type": "error", "error": str(e)})

@app.route('/api/v0/get_training_data', methods=['GET'])
def get_training_data():
    df = vn.get_training_data()

    return jsonify(
        {
            "type": "df",
            "df": df.head(25).to_json(orient='records'),
        })

@app.route('/api/v0/remove_training_data', methods=['POST'])
def remove_training_data():
    # Get id from the JSON body
    id = flask.request.json.get('id')

    if id is None:
        return jsonify({"type": "error", "error": "No id provided"})

    if vn.remove_training_data(id=id):
        return jsonify({"success": True})
    else:
        return jsonify({"type": "error", "error": "Couldn't remove training data"})

@app.route('/api/v0/train', methods=['POST'])
def add_training_data():
    question = flask.request.json.get('question')
    sql = flask.request.json.get('sql')
    ddl = flask.request.json.get('ddl')
    documentation = flask.request.json.get('documentation')

    try:
        id = vn.train(question=question, sql=sql, ddl=ddl, documentation=documentation)

        return jsonify({"id": id})
    except Exception as e:
        print("TRAINING ERROR", e)
        return jsonify({"type": "error", "error": str(e)})

@app.route('/api/v0/generate_followup_questions', methods=['GET'])
@requires_cache(['df', 'question', 'sql'])
def generate_followup_questions(df, question, sql):
    followup_questions = vn.generate_followup_questions(question=question, sql=sql, df=df)

    return jsonify(
        {
            "type": "question_list",
            "questions": followup_questions,
            "header": "Here are some followup questions you can ask:"
        })

@app.route('/api/v0/load_question', methods=['GET'])
@requires_cache(['question', 'sql', 'df', 'fig_html'])
def load_question(question, sql, df, fig_html):
    try:
        return jsonify(
            {
                "type": "question_cache",
                "question": question,
                "sql": sql,
                "df": df.head(10).to_json(orient='records'),
                "fig": fig_html,
            })
    except Exception as e:
        return jsonify({"type": "error", "error": str(e)})

@app.route('/api/v0/get_question_history', methods=['GET'])
def get_question_history():
    return jsonify({"type": "question_history", "questions": cache.get_all(field_list=['question']) })

@app.route('/')
def root():
    return app.send_static_file('index.html')

if __name__ == '__main__':
    app.run(debug=False, host='0.0.0.0', port=5000)
