# -*- coding: utf-8 -*-
from flask import Flask, request, render_template, session
import subprocess
import os

app = Flask(__name__)
app.secret_key = 'sysai-secret'  # Necesario para usar session

COMANDOS = {
    "free -h": ["memoria", "ram", "mem"],
    "top -bn1 | head -15": ["cpu", "procesador", "carga", "uso de cpu"],
    "df -h": ["disco", "espacio", "almacenamiento"],
    "uptime": ["uptime", "tiempo activo", "encendido"]
}

def ejecutar_comando(cmd):
    try:
        output_bytes = subprocess.check_output(cmd, shell=True, stderr=subprocess.PIPE)
        return output_bytes.decode('utf-8', errors='replace').strip()
    except subprocess.CalledProcessError as e:
        err = e.stderr.decode('utf-8', errors='replace').strip() if e.stderr else str(e)
        return f"Error al ejecutar comando: {err}"

def responder_sistema(pregunta):
    pregunta = pregunta.lower()
    for comando, claves in COMANDOS.items():
        if any(p in pregunta for p in claves):
            if any(p in pregunta for p in ["disco", "espacio", "almacenamiento"]):
                texto = "\u00BFEspecifica ruta a buscar archivos pesados? Ej: /home, /var, /mnt"
                return ejecutar_comando(comando), texto
            else:
                return ejecutar_comando(comando), None
    return None, None

@app.route("/", methods=["GET", "POST"])
def index():
    respuesta = None
    sugerencia = None
    mostrar_input_ruta = False

    if request.method == "POST":
        prompt = request.form.get("prompt", "").strip()
        ruta = request.form.get("ruta", "").strip()

        if prompt.lower() == "volver_disco":
            resultado = session.get("ultima_respuesta_disco") or ejecutar_comando("df -h")
            respuesta = f"Respuesta del sistema:\n{resultado}"
            sugerencia = "ruta"  # Muestra el campo de ruta nuevamente
            mostrar_input_ruta = True

        elif ruta:
            if os.path.exists(ruta):
                cmd = f"du -ah {ruta} | sort -rh | head -20"
                respuesta = f"Archivos más pesados en {ruta}:\n" + ejecutar_comando(cmd)
                sugerencia = "volver_disco"
            else:
                respuesta = f"La ruta '{ruta}' no existe o no es accesible."
                mostrar_input_ruta = True

        else:
            resultado, sugerencia_texto = responder_sistema(prompt)
            if resultado:
                respuesta = f"Respuesta del sistema:\n{resultado}"
                if "disco" in prompt.lower():
                    session["ultima_respuesta_disco"] = resultado
                if sugerencia_texto:
                    sugerencia = "ruta"
                    mostrar_input_ruta = True
            else:
                respuesta = (
                    "? Comando no reconocido.\n"
                    "Solo se permiten preguntas sobre: memoria, CPU, disco o uptime."
                )

    return render_template(
        "index.html",
        respuesta=respuesta,
        sugerencia=sugerencia,
        mostrar_input_ruta=mostrar_input_ruta,
    )

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=5000, debug=True)
