import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rackdoc_frontend/main.dart';
import 'package:rackdoc_frontend/models/datacenter_models.dart';

void main() {
  group('RackDocApp UI & SelectionArea smoke tests', () {
    testWidgets(
      'Renders login gate wrapped in global SelectionArea',
      (WidgetTester tester) async {
        await tester.pumpWidget(const RackDocApp());

        expect(find.byType(SelectionArea), findsOneWidget);
        expect(find.text('RackDoc8 DCIM'), findsOneWidget);
        expect(find.text('Usuario (Username)'), findsOneWidget);
        expect(find.text('Contraseña (Password)'), findsOneWidget);
      },
    );
  });

  group('Domain models & RBAC matrix tests', () {
    test('UserModel enforces 4-tier RBAC permissions accurately', () {
      final admin = UserModel.fromJson({
        'id': 1,
        'username': 'admin',
        'role': 'admin',
        'auth_source': 'local',
      });
      final editor = UserModel.fromJson({
        'id': 2,
        'username': 'editor1',
        'role': 'editor',
        'auth_source': 'ad',
        'ad_dn': 'CN=editor1,OU=IT,DC=corp,DC=local',
      });
      final operatorUser = UserModel.fromJson({
        'id': 3,
        'username': 'noc1',
        'role': 'operator',
      });
      final viewer = UserModel.fromJson({
        'id': 4,
        'username': 'audit1',
        'role': 'viewer',
      });

      expect(admin.isAdmin, isTrue);
      expect(admin.canEdit, isTrue);
      expect(admin.canConnectRemote, isTrue);

      expect(editor.isAdmin, isFalse);
      expect(editor.canEdit, isTrue);
      expect(editor.canConnectRemote, isTrue);
      expect(editor.authSource, 'ad');

      expect(operatorUser.canEdit, isFalse);
      expect(operatorUser.canConnectRemote, isTrue);

      expect(viewer.canEdit, isFalse);
      expect(viewer.canConnectRemote, isFalse);
    });

    test('ADServerModel detects LDAPS port and SSL flag from ldap_url', () {
      final ldapsServer = ADServerModel.fromJson({
        'id': 10,
        'name': 'AD Corporativo',
        'ldap_url': 'ldaps://dc01.corp.local',
        'domain': 'corp.local',
        'base_dn': 'DC=corp,DC=local',
      });
      expect(ldapsServer.useSsl, isTrue);
      expect(ldapsServer.port, 636);
      expect(ldapsServer.isActive, isTrue);
    });
  });
}
