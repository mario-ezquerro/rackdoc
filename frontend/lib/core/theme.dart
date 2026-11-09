import 'package:flutter/material.dart';

/// Paleta base de RackDoc.
///
/// No es una paleta inventada: son los 50 colores que la interfaz ya venía
/// usando (la escala de Tailwind), que hasta ahora estaban escritos a mano como
/// literales `Color(0xFF……)` repartidos por los ficheros de pantalla —1.661
/// apariciones—, de modo que no había forma de ver cuáles eran el mismo color
/// ni de cambiar la paleta sin un buscar-y-reemplazar a ciegas.
///
/// Para color nuevo, usa preferentemente los nombres semánticos de [AppTheme];
/// recurre a la escala solo cuando ninguno encaje.
class AppPalette {
  const AppPalette._();

  // Neutros (grises azulados): fondos, bordes y texto.
  static const Color slate50 = Color(0xFFF8FAFC);
  static const Color slate100 = Color(0xFFF1F5F9);
  static const Color slate200 = Color(0xFFE2E8F0);
  static const Color slate300 = Color(0xFFCBD5E1);
  static const Color slate400 = Color(0xFF94A3B8);
  static const Color slate500 = Color(0xFF64748B);
  static const Color slate600 = Color(0xFF475569);
  static const Color slate700 = Color(0xFF334155);
  static const Color slate800 = Color(0xFF1E293B);
  static const Color slate900 = Color(0xFF0F172A);

  // Azul: color principal del producto.
  static const Color blue50 = Color(0xFFEFF6FF);
  static const Color blue100 = Color(0xFFDBEAFE);
  static const Color blue300 = Color(0xFF93C5FD);
  static const Color blue500 = Color(0xFF3B82F6);
  static const Color blue600 = Color(0xFF2563EB);
  static const Color blue700 = Color(0xFF1D4ED8);
  static const Color blue900 = Color(0xFF1E3A8A);

  // Celeste: acentos, enlaces de fibra y gráficas.
  static const Color sky50 = Color(0xFFF0F9FF);
  static const Color sky100 = Color(0xFFE0F2FE);
  static const Color sky200 = Color(0xFFBAE6FD);
  static const Color sky400 = Color(0xFF38BDF8);
  static const Color sky600 = Color(0xFF0284C7);
  static const Color sky700 = Color(0xFF0369A1);
  static const Color sky900 = Color(0xFF0C4A6E);

  // Rojo: errores, equipos caídos y colisiones de IP.
  static const Color red50 = Color(0xFFFEF2F2);
  static const Color red200 = Color(0xFFFECACA);
  static const Color red300 = Color(0xFFFCA5A5);
  static const Color red600 = Color(0xFFDC2626);
  static const Color red700 = Color(0xFFB91C1C);
  static const Color red800 = Color(0xFF991B1B);

  // Verde: estado correcto.
  static const Color green50 = Color(0xFFF0FDF4);
  static const Color green100 = Color(0xFFDCFCE7);
  static const Color green300 = Color(0xFF86EFAC);
  static const Color green600 = Color(0xFF16A34A);
  static const Color green700 = Color(0xFF15803D);
  static const Color emerald500 = Color(0xFF10B981);

  // Ámbar: avisos y mantenimientos.
  static const Color amber50 = Color(0xFFFFFBEB);
  static const Color amber100 = Color(0xFFFEF3C7);
  static const Color amber300 = Color(0xFFFCD34D);
  static const Color amber500 = Color(0xFFF59E0B);
  static const Color amber600 = Color(0xFFD97706);
  static const Color amber700 = Color(0xFFB45309);
  static const Color amber800 = Color(0xFF92400E);

  // Otros acentos usados en diagramas y categorías.
  static const Color teal600 = Color(0xFF0D9488);
  static const Color teal700 = Color(0xFF0F766E);
  static const Color cyan500 = Color(0xFF06B6D4);
  static const Color indigo100 = Color(0xFFE0E7FF);
  static const Color indigo600 = Color(0xFF4F46E5);
  static const Color violet600 = Color(0xFF7C3AED);
  static const Color orange600 = Color(0xFFEA580C);
}

/// Nombres semánticos sobre [AppPalette]: lo que significa cada color, no qué
/// tono es. Estaba declarado dentro de network_hosts_view.dart, donde ningún
/// otro fichero podía verlo.
class AppTheme {
  const AppTheme._();

  static const Color bgPrimary = AppPalette.slate50;
  static const Color bgSecondary = Color(0xFFFFFFFF);
  static const Color bgCard = AppPalette.slate100;
  static const Color bgElevated = AppPalette.slate200;
  static const Color border = AppPalette.slate300;
  static const Color textPrimary = AppPalette.slate900;
  static const Color textSecondary = AppPalette.slate700;
  static const Color textMuted = AppPalette.slate500;
  static const Color accentCyan = AppPalette.sky600;
  static const Color accentBlue = AppPalette.blue600;
  static const Color accentPurple = AppPalette.violet600;
  static const Color accentTeal = AppPalette.teal600;
  static const Color success = AppPalette.green600;
  static const Color warning = AppPalette.amber600;
  static const Color error = AppPalette.red600;
}
