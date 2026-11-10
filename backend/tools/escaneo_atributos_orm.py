#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Busca accesos a atributos de modelos SQLAlchemy que no existen.

Python no avisa de esto: `equipo.columna_que_no_existe` es sintaxis válida y
revienta en ejecución, la primera vez que alguien pisa esa rama. Tres de los
fallos de noviembre de 2026 fueron exactamente eso, y aparecieron de uno en
uno, en producción.

Qué comprueba, leyendo models.py como árbol sintáctico:

  A) referencias de clase        models.Clase.attr  /  Clase.attr
  B) accesos sobre instancia     se infiere el modelo de la variable
  C) argumentos de constructor   Modelo(kwarg=...) con kwarg no declarado

Para (B) es deliberadamente conservador: si un nombre se liga más de una vez
dentro de la misma función (reasignado, reutilizado en una comprensión, en un
'with', en un 'except'...) y no sale siempre el mismo modelo, el nombre se
descarta entero. Un falso positivo cuesta más que un hallazgo perdido.

Uso, desde el directorio backend/:

    python3 tools/escaneo_atributos_orm.py

Devuelve 1 si encuentra algo, para poder colgarlo de un hook o de CI.
"""
import ast
import os
import sys

RAIZ = "app"
MODELOS = os.path.join(RAIZ, "models.py")
DESCONOCIDO = ("?", None)

HEREDADOS = {"metadata", "registry", "query", "_sa_instance_state",
             "_sa_class_manager", "__table__", "__tablename__", "__mapper__",
             "__dict__", "__class__"}

# ---------------------------------------------------------------- esquema ---
arbol = ast.parse(open(MODELOS, encoding="utf-8").read(), MODELOS)
esquema = {}
for nodo in arbol.body:
    if not (isinstance(nodo, ast.ClassDef)
            and any(isinstance(b, ast.Name) and b.id == "Base" for b in nodo.bases)):
        continue
    attrs = {}
    for item in nodo.body:
        if isinstance(item, (ast.Assign, ast.AnnAssign)):
            objetivos = item.targets if isinstance(item, ast.Assign) else [item.target]
            v, clase, destino = item.value, "otro", None
            if isinstance(v, ast.Call) and isinstance(v.func, ast.Name):
                if v.func.id == "Column":
                    clase = "column"
                elif v.func.id == "relationship":
                    clase = "relationship"
                    if v.args and isinstance(v.args[0], ast.Constant):
                        destino = v.args[0].value
            for t in objetivos:
                if isinstance(t, ast.Name):
                    attrs[t.id] = (clase, destino)
        elif isinstance(item, (ast.FunctionDef, ast.AsyncFunctionDef)):
            attrs[item.name] = ("otro", None)
    esquema[nodo.name] = attrs


def relacion_simple(clase, attr):
    """True si la relacion apunta a UN objeto (hay columna <attr>_id propia)."""
    return attr + "_id" in esquema.get(clase, {})


print("models.py: %d clases, %d atributos declarados"
      % (len(esquema), sum(len(a) for a in esquema.values())))


def ficheros():
    for base, _, nombres in os.walk(RAIZ):
        for n in sorted(nombres):
            r = os.path.join(base, n)
            if n.endswith(".py") and r != MODELOS:
                yield r


class Analisis:
    def __init__(self, alias):
        self.alias = alias
        self.hallazgos = []

    def clase_de(self, nodo):
        if isinstance(nodo, ast.Attribute) and isinstance(nodo.value, ast.Name) \
                and nodo.value.id == "models" and nodo.attr in esquema:
            return nodo.attr
        if isinstance(nodo, ast.Name) and self.alias.get(nodo.id) in esquema:
            return self.alias[nodo.id]
        return None

    # --- inferencia de tipo de una expresion, con un mapa de variables ----
    def tipo(self, nodo, mapa):
        if isinstance(nodo, ast.Name):
            return mapa.get(nodo.id)
        if isinstance(nodo, ast.Attribute):
            t = self.tipo(nodo.value, mapa)
            if t and t[0] == "uno":
                info = esquema.get(t[1], {}).get(nodo.attr)
                if info and info[0] == "relationship" and info[1] in esquema:
                    return ("uno" if relacion_simple(t[1], nodo.attr) else "muchos", info[1])
            return None
        if isinstance(nodo, ast.Call):
            c = self.clase_de(nodo.func)
            if c:
                return ("uno", c)
            if isinstance(nodo.func, ast.Attribute):
                m = nodo.func.attr
                if m == "get" and nodo.args:
                    c = self.clase_de(nodo.args[0])
                    if c:
                        return ("uno", c)
                if m in ("first", "one", "one_or_none", "scalar", "all", "scalars"):
                    cur = nodo.func.value
                    while isinstance(cur, ast.Call) and isinstance(cur.func, ast.Attribute):
                        if cur.func.attr == "query":
                            c = self.clase_de(cur.args[0]) if cur.args else None
                            return (("muchos" if m in ("all", "scalars") else "uno"), c) if c else None
                        cur = cur.func.value
            return None
        if isinstance(nodo, ast.Subscript):          # lista[i] de una coleccion
            t = self.tipo(nodo.value, mapa)
            return ("uno", t[1]) if t and t[0] == "muchos" else None
        return None

    # --- todos los puntos donde un nombre queda ligado en la funcion ------
    def ligaduras(self, func, mapa):
        """{nombre: tipo} o DESCONOCIDO si se liga de formas distintas."""
        res = {}

        def poner(nombre, t):
            t = t or DESCONOCIDO
            if nombre in res and res[nombre] != t:
                res[nombre] = DESCONOCIDO
            else:
                res[nombre] = t

        def nombres_de(obj):
            if isinstance(obj, ast.Name):
                return [obj.id]
            if isinstance(obj, (ast.Tuple, ast.List)):
                return [n for e in obj.elts for n in nombres_de(e)]
            return []

        for n in ast.walk(func):
            if isinstance(n, (ast.FunctionDef, ast.AsyncFunctionDef, ast.Lambda)) and n is not func:
                # funciones anidadas: sus ligaduras tambien ensucian el nombre
                for a in list(n.args.args) + list(n.args.kwonlyargs):
                    poner(a.arg, None)
                continue
            if isinstance(n, ast.Assign):
                t = self.tipo(n.value, mapa)
                for obj in n.targets:
                    for nom in nombres_de(obj):
                        poner(nom, t if isinstance(obj, ast.Name) else None)
            elif isinstance(n, ast.AnnAssign) and isinstance(n.target, ast.Name):
                c = self.clase_de(n.annotation)
                poner(n.target.id, ("uno", c) if c else self.tipo(n.value, mapa) if n.value else None)
            elif isinstance(n, (ast.AugAssign, ast.NamedExpr)):
                for nom in nombres_de(n.target):
                    poner(nom, None)
            elif isinstance(n, ast.For):
                t = self.tipo(n.iter, mapa)
                for nom in nombres_de(n.target):
                    poner(nom, ("uno", t[1]) if (t and t[0] == "muchos"
                                                 and isinstance(n.target, ast.Name)) else None)
            elif isinstance(n, ast.comprehension):
                t = self.tipo(n.iter, mapa)
                for nom in nombres_de(n.target):
                    poner(nom, ("uno", t[1]) if (t and t[0] == "muchos"
                                                 and isinstance(n.target, ast.Name)) else None)
            elif isinstance(n, ast.withitem):
                for nom in nombres_de(n.optional_vars) if n.optional_vars else []:
                    poner(nom, None)
            elif isinstance(n, ast.ExceptHandler) and n.name:
                poner(n.name, None)
            elif isinstance(n, (ast.Import, ast.ImportFrom)):
                for a in n.names:
                    poner((a.asname or a.name).split(".")[0], None)
            elif isinstance(n, ast.Global) or isinstance(n, ast.Nonlocal):
                for nom in n.names:
                    poner(nom, None)
        return res

    def funcion(self, func, globales):
        mapa = dict(globales)
        for a in list(func.args.args) + list(func.args.kwonlyargs):
            c = self.clase_de(a.annotation) if a.annotation is not None else None
            mapa[a.arg] = ("uno", c) if c else DESCONOCIDO
        # dos rondas: la segunda resuelve cadenas (x = cert.asset; x.foo)
        for _ in range(2):
            nuevo = dict(mapa)
            nuevo.update(self.ligaduras(func, mapa))
            for a in list(func.args.args) + list(func.args.kwonlyargs):
                c = self.clase_de(a.annotation) if a.annotation is not None else None
                if c:
                    nuevo[a.arg] = ("uno", c)
            mapa = nuevo
        # C) argumentos de constructor: Modelo(kw=...) con kw no declarado
        for n in ast.walk(func):
            if isinstance(n, ast.Call):
                c = self.clase_de(n.func)
                if c:
                    for kw in n.keywords:
                        if kw.arg and kw.arg not in esquema[c]:
                            self.hallazgos.append(("constructor", n.lineno, c, kw.arg))
        # comprobacion de accesos
        for n in ast.walk(func):
            if not isinstance(n, ast.Attribute):
                continue
            c = self.clase_de(n.value)
            if c:
                if n.attr not in esquema[c] and n.attr not in HEREDADOS:
                    self.hallazgos.append(("clase", n.lineno, c, n.attr))
                continue
            t = self.tipo(n.value, mapa)
            if t and t[0] == "uno" and t[1] in esquema:
                if n.attr not in esquema[t[1]] and n.attr not in HEREDADOS:
                    self.hallazgos.append(("instancia", n.lineno, t[1], n.attr))


total, por_fichero = 0, {}
for ruta in ficheros():
    arb = ast.parse(open(ruta, encoding="utf-8").read(), ruta)
    alias = {}
    for n in ast.walk(arb):
        if isinstance(n, ast.ImportFrom) and n.module and n.module.endswith("models"):
            for a in n.names:
                if a.name in esquema:
                    alias[a.asname or a.name] = a.name
    an = Analisis(alias)
    funcs = [n for n in ast.walk(arb) if isinstance(n, (ast.FunctionDef, ast.AsyncFunctionDef))]
    for f in funcs:
        an.funcion(f, {})
    # nivel de modulo: solo referencias de clase
    for n in ast.walk(arb):
        if isinstance(n, ast.Attribute):
            c = an.clase_de(n.value)
            if c and n.attr not in esquema[c] and n.attr not in HEREDADOS:
                an.hallazgos.append(("clase", n.lineno, c, n.attr))
        elif isinstance(n, ast.Call):
            c = an.clase_de(n.func)
            if c:
                for kw in n.keywords:
                    if kw.arg and kw.arg not in esquema[c]:
                        an.hallazgos.append(("constructor", n.lineno, c, kw.arg))
    vistos, limpios = set(), []
    for h in an.hallazgos:
        if h not in vistos:
            vistos.add(h)
            limpios.append(h)
    if limpios:
        por_fichero[ruta] = limpios
        total += len(limpios)

for ruta, hs in sorted(por_fichero.items()):
    src = open(ruta, encoding="utf-8").read().split("\n")
    print("\n%s" % ruta)
    for tipo_acc, ln, modelo, attr in sorted(hs, key=lambda h: h[1]):
        print("  linea %-5d %-9s %s.%s" % (ln, tipo_acc, modelo, attr))
        print("              | %s" % src[ln - 1].strip()[:110])

print("\n=== atributos inexistentes: %d ===" % total)
sys.exit(1 if total else 0)
