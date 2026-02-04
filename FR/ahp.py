import numpy as np


def normalize_matrix(matrix):

    column_sum = matrix.sum(0)
    return matrix/column_sum


def calculate_weights(normalized_matrix):
    return normalized_matrix.mean(axis=1)


def consistency_ratio(matrix, weights):
    import numpy as np

    # RI valores según el tamaño de la matriz
    RI_dict = {1: 0.00, 2: 0.00, 3: 0.58, 4: 0.90, 5: 1.12, 6: 1.24, 7: 1.32, 8: 1.41, 9: 1.45}

    n = matrix.shape[0]  # Tamaño de la matriz
    # Calcular λ_max correctamente
    weighted_sum = np.dot(matrix, weights)
    lambda_max = np.mean(weighted_sum / weights)

    # Calcular CI (Índice de Consistencia)
    CI = (lambda_max - n) / (n - 1)

    # Recuperar RI correspondiente al tamaño de la matriz
    RI = RI_dict.get(n, 1.45)

    # Calcular CR (Razón de Consistencia)
    CR = CI / RI if RI != 0 else 0

    return CR




