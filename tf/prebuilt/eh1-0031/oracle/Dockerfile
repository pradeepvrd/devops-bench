FROM devops-bench/oltp-writer:1.0.0
ENV PYTHONDONTWRITEBYTECODE=1
COPY requirements.txt /requirements.txt
RUN pip install --no-cache-dir --require-hashes -r /requirements.txt
COPY challenge.py startup.py /oracle/
ENTRYPOINT ["python", "/oracle/challenge.py"]
CMD ["monitor"]
