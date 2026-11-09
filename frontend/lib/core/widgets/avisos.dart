import 'package:flutter/material.dart';

import '../theme.dart';

/// Avisos (SnackBars) con un estilo único para toda la aplicación.
///
/// Antes cada pantalla construía su propio `SnackBar` a mano: había 117
/// llamadas a `showSnackBar` con 37 formas distintas, y el aviso de error
/// —`SnackBar(content: Text('$e'), backgroundColor: Colors.red.shade700)`—
/// estaba copiado literalmente 22 veces.
///
/// Es una extensión sobre `ScaffoldMessengerState`, no sobre `BuildContext`,
/// a propósito: así se sigue pudiendo capturar el messenger *antes* de un
/// `await` y evitar usar el contexto después de un hueco asíncrono.
extension Avisos on ScaffoldMessengerState {
  /// Aviso de error. Acepta la excepción tal cual y le quita el prefijo
  /// "Exception: " que añade Dart, que no aporta nada al usuario.
  void avisoError(Object error) {
    final texto = error.toString().replaceFirst('Exception: ', '');
    showSnackBar(
      SnackBar(
        content: Text(texto),
        backgroundColor: _rojoError,
      ),
    );
  }

  /// Aviso informativo, con el estilo por defecto.
  void aviso(String mensaje) {
    showSnackBar(SnackBar(content: Text(mensaje)));
  }

  /// Aviso de operación correcta.
  void avisoExito(String mensaje) {
    showSnackBar(
      SnackBar(
        content: Text(mensaje),
        backgroundColor: AppPalette.green700,
      ),
    );
  }
}

/// El rojo que ya usaban los avisos de error (Material red 700). No es el
/// AppPalette.red700 de la paleta del producto; se conserva el original para
/// que este cambio no altere nada visualmente. Unificarlo es una decisión de
/// diseño, no de refactor.
final Color _rojoError = Colors.red.shade700;
