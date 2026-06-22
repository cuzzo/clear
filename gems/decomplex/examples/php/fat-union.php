<?php
function handle($node) {
  switch ($node) {
    case AST::Call:
      $node->line();
      $node->col();
      $node->ty();
      $node->span();
      $node->parent();
      $node->recv();
      break;
    case AST::Func:
      $node->line();
      $node->col();
      $node->ty();
      $node->span();
      $node->parent();
      $node->name();
      break;
    case AST::Lit:
      $node->line();
      $node->col();
      $node->ty();
      $node->span();
      $node->parent();
      $node->value();
      break;
  }
}
