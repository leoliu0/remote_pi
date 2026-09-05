import 'package:app/domain/contracts/contracts.dart';
import 'package:app/ui/core/viewmodel/viewmodel.dart';
import 'package:auto_injector/auto_injector.dart';

/// Typed facade over [AutoInjector] centralizing the configuration of services,
/// repositories, use cases, and view models with proper lifecycle disposal.
///
/// Typed methods (`addService`, `addRepository`, `addUseCase`,
/// `addViewModel`) self-document the layer and contract satisfied by each binding.
///
/// Use `addInstance` for pre-built instances (e.g. SDK singletons) and
/// `addOther` for non-domain infrastructure types (e.g. `Dio`, `Connectivity`).
class CustomInjector {
  final _injector = AutoInjector();

  /// Resolves a registered instance. For `ViewModel`s, each call returns
  /// a new instance (registered with `add`, not `addLazySingleton`).
  T get<T extends Object>() => _injector.get<T>();

  /// Registers a pre-built singleton instance.
  void addInstance<T>(T instance) {
    _injector.addInstance<T>(instance);
  }

  /// Registers a lazy singleton for infrastructure types outside domain contracts.
  void addOther<T>(Function constructor) {
    _injector.addLazySingleton<T>(constructor);
  }

  /// Registers a lazy singleton [Service], wiring `dispose()` to injector disposal.
  void addService<T extends Service>(Function constructor) {
    _injector.addLazySingleton<T>(
      constructor,
      config: BindConfig(onDispose: (value) => value.dispose()),
    );
  }

  /// Registers a lazy singleton [Repository], wiring `dispose()` to injector disposal.
  void addRepository<T extends Repository>(Function constructor) {
    _injector.addLazySingleton<T>(
      constructor,
      config: BindConfig(onDispose: (value) => value.dispose()),
    );
  }

  /// Registers a [ViewModel]; each `get` returns a fresh instance.
  void addViewModel<T extends ViewModel>(Function constructor) {
    _injector.add(constructor);
  }

  /// Registers a [UseCase] resolved on demand.
  void addUseCase<T extends UseCase>(Function constructor) {
    _injector.add(constructor);
  }

  /// Disposes all registered dependencies and resets the injector.
  void dispose() => _injector.dispose();

  /// Commits dependency registration and locks against further additions.
  void commit() => _injector.commit();
}
