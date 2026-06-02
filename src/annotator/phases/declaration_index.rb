# typed: strict
require "sorbet-runtime"

require_relative "../../ast/ast"

module Annotator
  module Phases
    extend T::Sig

    TypeDeclaration = T.type_alias do
      T.any(AST::StructDef, AST::ExternStructDecl, AST::EnumDef, AST::UnionDef)
    end

    class DeclarationIndex < T::Struct
      const :imports, T::Array[AST::RequireNode]
      const :type_declarations, T::Array[TypeDeclaration]
      const :function_declarations, T::Array[AST::FunctionDef]
      const :extern_function_declarations, T::Array[AST::ExternFnDecl]
      const :union_method_declarations, T::Array[AST::UnionDef]
      const :body_statements, T::Array[AST::Locatable]
    end

    class DeclarationIndexer
      extend T::Sig

      sig { params(program: AST::Program).returns(DeclarationIndex) }
      def self.index(program)
        imports = T.let([], T::Array[AST::RequireNode])
        type_declarations = T.let([], T::Array[TypeDeclaration])
        function_declarations = T.let([], T::Array[AST::FunctionDef])
        extern_function_declarations = T.let([], T::Array[AST::ExternFnDecl])
        union_method_declarations = T.let([], T::Array[AST::UnionDef])
        body_statements = T.let([], T::Array[AST::Locatable])

        program.statements.each do |stmt|
          case stmt
          when AST::RequireNode
            imports << stmt
          when AST::StructDef, AST::ExternStructDecl, AST::EnumDef
            type_declarations << stmt
          when AST::UnionDef
            type_declarations << stmt
            union_method_declarations << stmt if union_methods?(stmt)
          when AST::FunctionDef
            function_declarations << stmt
            body_statements << stmt
          when AST::ExternFnDecl
            extern_function_declarations << stmt
          else
            body_statements << stmt
          end
        end

        DeclarationIndex.new(
          imports: imports,
          type_declarations: type_declarations,
          function_declarations: function_declarations,
          extern_function_declarations: extern_function_declarations,
          union_method_declarations: union_method_declarations,
          body_statements: body_statements
        )
      end

      sig { params(node: AST::UnionDef).returns(T::Boolean) }
      def self.union_methods?(node)
        methods = node.methods
        !methods.nil? && !methods.empty?
      end
      private_class_method :union_methods?
    end
  end
end
